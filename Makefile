# Run and evaluation entry points (managed by AIRAS — not part of the agent's allowed files).
#
# `make run RUN_ID=<run_id> MODE=<sanity|pilot|full>` is the one entry point the
# workflows and airas call. What it runs is the run's kind, read from
# config/run/<run_id>.yaml:
#
#   (no kind)    an experiment: src.main, then airas-eval on its eval_inputs,
#                then src.evaluate for metrics.json and the figures
#   kind: lean   a proof: `lake build <module>` in lean/, then `lake exe
#                airas-report` writes .research/results/<run_id>/lean.json for
#                <decl>, checking it against the statement the record declares
#                for the run. The yaml names module and decl, and optionally
#                the namespaces whose scoped notations the declared statement
#                needs, e.g.
#                    kind: lean
#                    module: Airas.Thm1
#                    decl: thm1
#                    open: BigOperators,Finset
#                MODE is sanity (the statement type-checks, sorry allowed) or
#                full (a sorry-free proof); Lean has no pilot stage.
#
# Metrics are computed by airas-eval, never by experiment code. The experiment
# writes raw evaluation inputs; this Makefile runs the pinned airas-eval CLI on
# them. Task types come from the research plan (.research/evaluation.json);
# workflows may override via AIRAS_EVAL_TASKS. Scores seen here are for the
# agent's own iteration — the official numbers are recomputed by AIRAS from the
# same input files in an environment the agent cannot edit. Likewise lean.json
# is written by airas-report, never by the proof's author, for the record gate
# to re-derive.

RESULTS_DIR      ?= .research/results
MODE             ?= full
EVAL_PLAN        ?= .research/evaluation.json
LEAN_DIR         ?= lean
AIRAS_EVAL_TASKS ?= $(shell python3 -c 'import json,sys; d=json.load(open("$(EVAL_PLAN)")); print(" ".join(d.get("task_types", [])))')
AIRAS_EVAL        = uv run --group eval airas-eval

# RUN_ID and MODE come from workflow inputs and the run config's values from a
# file the agent writes, so recipes read them as shell variables ($$RUN_ID, and
# `$(call run_config_value,key)` into a local) and check their characters
# before using them: pasting them into recipe text would let a value such as
# `$(...)` run as a command, or a RUN_ID such as `../x` write outside RESULTS_DIR.
export RUN_ID MODE RESULTS_DIR LEAN_DIR

# Shell text that prints `key: value` from config/run/$RUN_ID.yaml, with quotes
# and a trailing comment stripped. $(1) is a literal key from this Makefile.
run_config_value  = sed -n 's/^$(1):[[:space:]]*//p' "config/run/$$RUN_ID.yaml" 2>/dev/null \
                      | sed -e 's/[[:space:]]*\#.*$$//' -e 's/^"\(.*\)"$$/\1/' -e "s/^'\(.*\)'$$/\1/" | head -1

.PHONY: run run-experiment run-lean evaluate validate-inputs schema list-tasks

## Run one run_id at one stage: make run RUN_ID=<run_id> MODE=<sanity|pilot|full>
run: _require_run_id
	@kind=$$($(call run_config_value,kind)); \
	case "$$kind" in \
	  ""|experiment) $(MAKE) run-experiment ;; \
	  lean)          $(MAKE) run-lean ;; \
	  *) echo "unknown kind '$$kind' in config/run/$$RUN_ID.yaml: expected no kind (an experiment) or 'lean'"; exit 1 ;; \
	esac

## The experiment chain. A run that stops after src.main leaves no metrics.json
## for the record gate to compare, so the three steps are one target.
run-experiment: _require_run_id
	uv run python -u -m src.main run=$$RUN_ID results_dir="$$RESULTS_DIR" mode=$$MODE
	$(MAKE) evaluate
	uv run python -u -m src.evaluate results_dir="$$RESULTS_DIR" run_ids="[\"$$RUN_ID\"]"

## A proof. The build log is kept next to lean.json and airas-report reads it,
## so a failed build is reported rather than hidden; the run fails if either
## the build or the report did, whatever the other said.
run-lean: _require_run_id
	@module=$$($(call run_config_value,module)); decl=$$($(call run_config_value,decl)); \
	opens=$$($(call run_config_value,open)); \
	test -n "$$module" && test -n "$$decl" \
	  || { echo "config/run/$$RUN_ID.yaml must name 'module' and 'decl' for a lean run"; exit 1; }; \
	case "$$module$$decl$$opens" in *[!A-Za-z0-9_.,\']*) \
	  echo "'module', 'decl' and 'open' in config/run/$$RUN_ID.yaml may hold only letters, digits, '_', '.', ',' and \"'\""; exit 1 ;; esac; \
	case "$$MODE" in sanity|full) ;; *) \
	  echo "Lean runs have no '$$MODE' stage: use sanity (the statement type-checks, sorry allowed) or full (a sorry-free proof)"; exit 1 ;; esac; \
	run_dir="$(abspath $(RESULTS_DIR))/$$RUN_ID"; mkdir -p "$$run_dir"; \
	cd "$$LEAN_DIR" || exit 1; \
	lake exe cache get || exit 1; \
	build_status=0; lake build "$$module" > "$$run_dir/build.txt" 2>&1 || build_status=$$?; \
	cat "$$run_dir/build.txt"; \
	report_status=0; lake exe airas-report --module "$$module" --decl "$$decl" --mode "$$MODE" \
	  --record "$(abspath .research/record.json)" --run-id "$$RUN_ID" --open "$$opens" \
	  --build-log "$$run_dir/build.txt" --out "$$run_dir/lean.json" || report_status=$$?; \
	test "$$build_status" -eq 0 || { echo "lake build $$module failed (exit $$build_status)"; exit 1; }; \
	exit "$$report_status"
	@case "$$MODE" in sanity) echo "SANITY_VALIDATION: PASS" ;; esac

## Score every task type in the plan for one run: make evaluate RUN_ID=<run_id>
evaluate: _require_run_id _require_tasks
	@mkdir -p "$(RESULTS_DIR)/$(RUN_ID)/evaluation"
	@for t in $(AIRAS_EVAL_TASKS); do \
		echo "=== [AIRAS-EVAL] $$t for $(RUN_ID)"; \
		$(AIRAS_EVAL) score $$t \
			--inputs "$(RESULTS_DIR)/$(RUN_ID)/eval_inputs/$$t.json" \
			--output "$(RESULTS_DIR)/$(RUN_ID)/evaluation/$$t.json" || exit 1; \
	done

## Check the input files against the contract without scoring
validate-inputs: _require_run_id _require_tasks
	@for t in $(AIRAS_EVAL_TASKS); do \
		$(AIRAS_EVAL) validate $$t --inputs "$(RESULTS_DIR)/$(RUN_ID)/eval_inputs/$$t.json" || exit 1; \
	done

## Print the JSON Schema of the input file(s) the experiment must produce
schema: _require_tasks
	@for t in $(AIRAS_EVAL_TASKS); do $(AIRAS_EVAL) schema $$t; done

## Print what each planned task type returns
list-tasks: _require_tasks
	@for t in $(AIRAS_EVAL_TASKS); do $(AIRAS_EVAL) list $$t; done

_require_run_id:
	@test -n "$$RUN_ID" || { echo "RUN_ID is required, e.g. make evaluate RUN_ID=proposed-resnet-cifar10"; exit 1; }
	@case "$$RUN_ID" in *[!A-Za-z0-9_.-]*|.*) \
	  echo "RUN_ID '$$RUN_ID' may hold only letters, digits, '_', '.' and '-', and may not start with '.'"; exit 1 ;; esac

_require_tasks:
	@test -n "$(AIRAS_EVAL_TASKS)" || { echo "no task types: $(EVAL_PLAN) has no task_types and AIRAS_EVAL_TASKS is unset"; exit 1; }
