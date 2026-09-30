import Lean

/-!
`lake exe airas-report --module <M> --decl <d> --mode <sanity|full>
  [--record <record.json> --run-id <id>] [--open <ns,ns>]
  [--build-log <path>] [--out <path>]`

Writes the `lean.json` report of one declaration after `lake build <M>`:

- `statement`: the declaration's type as Lean prints it (what `#check @d` shows)
- `statement_matches`: whether the type the record declared for this run
  (`params.statement`, elaborated here in the module's environment) is the
  built declaration's type, compared as terms up to bound-variable names —
  so the record may spell the type any way Lean accepts, and a proof of a
  definitionally equal but different statement (`n = n` for `n + 0 = n`)
  still does not match. `null` when the record has no entry for this run;
  a record that cannot be read is an error, not a missing entry. `--open`
  names the namespaces whose scoped notations and short names the declared
  statement relies on (mathlib's `∑` and `ℕ` need none).
- `axioms`: every axiom the declaration depends on, `sorryAx` included
- `errors` / `warnings`: the build log's error and warning lines; an import
  or lookup failure is an error too, so a failed build is still a report
- `toolchain`, `mathlib_rev`, `commit`: what was built, from `lean-toolchain`,
  `lake-manifest.json` and `AIRAS_COMMIT` / `GITHUB_SHA` / git

It does not judge the claim: whether the statement matches the record, and
which axioms are allowed, is decided by airas from this file. The exit code
only says whether the run itself passed — a failed build or a declared
statement that does not match fails the run in both modes, and in `full`
mode so does a proof that uses `sorry` — so `make run` can fail the job the
way an experiment crash would.

Managed by AIRAS. The record gate is to re-derive this report from its own
copy of the tool (airas-org/airas#1020), so editing this file is not a way to
change what the gate believes.
-/
open Lean Meta

structure Args where
  module : String := ""
  decl : String := ""
  mode : String := "full"
  buildLog : Option String := none
  out : String := "lean.json"
  record : Option String := none
  runId : Option String := none
  opens : String := ""
  toolchainFile : String := "lean-toolchain"
  manifestFile : String := "lake-manifest.json"

partial def parseArgs : List String → Args → Except String Args
  | [], a => .ok a
  | "--module" :: v :: rest, a => parseArgs rest { a with module := v }
  | "--decl" :: v :: rest, a => parseArgs rest { a with decl := v }
  | "--mode" :: v :: rest, a => parseArgs rest { a with mode := v }
  | "--build-log" :: v :: rest, a => parseArgs rest { a with buildLog := some v }
  | "--out" :: v :: rest, a => parseArgs rest { a with out := v }
  | "--record" :: v :: rest, a => parseArgs rest { a with record := some v }
  | "--run-id" :: v :: rest, a => parseArgs rest { a with runId := some v }
  | "--open" :: v :: rest, a => parseArgs rest { a with opens := v }
  | "--toolchain-file" :: v :: rest, a => parseArgs rest { a with toolchainFile := v }
  | "--manifest-file" :: v :: rest, a => parseArgs rest { a with manifestFile := v }
  | arg :: _, _ => .error s!"unknown argument '{arg}'"

-- `enableInitializersExecution` is unsafe; `importModules (loadExts := true)`
-- needs it so mathlib's notation delaborators are live when the type is printed.
unsafe def enableInitializersUnsafe : IO Unit := enableInitializersExecution
@[implemented_by enableInitializersUnsafe] def enableInitializers : IO Unit := pure ()

def trimmed (s : String) : String := s.trimAscii.toString

def readFileOrEmpty (path : System.FilePath) : IO String := do
  if ← path.pathExists then IO.FS.readFile path else pure ""

/-- The build log's lines at one level. Lake prints
`error: <file>:<line>:<col>: <message>` and `warning: ...`, possibly behind a
progress prefix; the whole line is kept. -/
def logLines (log : String) (level : String) : List String :=
  log.splitOn "\n"
    |>.map trimmed
    |>.filter fun line => line.length > 0 && (line.splitOn s!"{level}:").length > 1

def manifestMathlibRev (path : System.FilePath) : IO String := do
  let text ← readFileOrEmpty path
  if text.isEmpty then return ""
  match Json.parse text with
  | .error _ => return ""
  | .ok json =>
    let packages := (json.getObjVal? "packages" >>= Json.getArr?).toOption.getD #[]
    for pkg in packages do
      if (pkg.getObjValAs? String "name").toOption == some "mathlib" then
        return (pkg.getObjValAs? String "rev").toOption.getD ""
    return ""

def commitSha : IO (Option String) := do
  for var in ["AIRAS_COMMIT", "GITHUB_SHA"] do
    if let some sha ← IO.getEnv var then
      if !(trimmed sha).isEmpty then return some (trimmed sha)
  try
    let out ← IO.Process.output { cmd := "git", args := #["rev-parse", "HEAD"] }
    if out.exitCode == 0 && !(trimmed out.stdout).isEmpty then return some (trimmed out.stdout)
  catch _ => pure ()
  return none

/-- `params.statement` of the run `runId` in the record: the last entry with
that run id, since a claim appended again under the same id is the live one.
`none` only when the record has no entry for the run; a record that is
missing or not JSON is an error, so the comparison cannot be switched off by
pointing at a broken file. -/
def declaredStatement (record : System.FilePath) (runId : String) :
    IO (Except String (Option String)) := do
  unless ← record.pathExists do
    return .error s!"the record {record} does not exist"
  let json ← match Json.parse (← IO.FS.readFile record) with
    | .ok json => pure json
    | .error e => return .error s!"the record {record} is not JSON: {e}"
  let arr (j : Json) (key : String) : Array Json :=
    (j.getObjVal? key >>= Json.getArr?).toOption.getD #[]
  let mut found : Option String := none
  for h in arr json "hypotheses" do
    for c in arr h "claims" do
      for d in arr c "designs" do
        for r in arr d "runs" do
          if (r.getObjValAs? String "run_id").toOption == some runId then
            if let some p := (r.getObjVal? "params").toOption then
              found := (p.getObjValAs? String "statement").toOption <|> found
  return .ok found

/-- The declared statement as a term of the module's environment, compared
with the built type up to bound-variable names (`Expr.eqv`). Definitional
unfolding is deliberately not used: a proof of a different statement that
happens to compute to the declared one is not the declared theorem. -/
def statementMatches (env : Environment) (opens : List Name) (declared : String)
    (built : Expr) : IO (Except String Bool) := do
  let elaborate : MetaM Bool := do
    -- `open scoped ns` for the notations, `open ns` for the short names.
    for ns in opens do activateScoped ns
    let stx ← match Parser.runParserCategory (← getEnv) `term declared with
      | .ok stx => pure stx
      | .error e => throwError "does not parse: {e}"
    let e ← withTheReader Core.Context
        (fun c => { c with openDecls := opens.map (OpenDecl.simple · []) }) do
      (Elab.Term.withoutErrToSorry do
        let e ← Elab.Term.elabType stx
        Elab.Term.synthesizeSyntheticMVarsNoPostponing
        instantiateMVars e).run'
    return e.eqv built
  try
    let (same, _, _) ← elaborate.toIO
      { fileName := "<declared statement>", fileMap := FileMap.ofString declared } { env }
    return .ok same
  catch ex =>
    return .error s!"the declared statement does not elaborate: {ex}"

structure Inspection where
  statement : String := ""
  statementMatches : Option Bool := none
  axioms : Array String := #[]
  errors : List String := []

def inspect (moduleName declName : String) (opens : List Name) (declared : Option String) :
    IO Inspection := do
  try
    initSearchPath (← findSysroot)
    let env ← importModules #[{ module := moduleName.toName }] {} 0 (loadExts := true)
    let name := declName.toName
    match env.find? name with
    | none =>
      return { errors := [s!"unknown declaration '{declName}' in module '{moduleName}'"] }
    | some info =>
      let ((fmt, axiomNames), _, _) ← (do
          pure (← Meta.ppExpr info.type, ← collectAxioms name) : MetaM (Format × Array Name)).toIO
        { fileName := "<airas-report>", fileMap := FileMap.ofString "" } { env }
      let axioms := axiomNames.map (·.toString) |>.qsort (· < ·)
      let statement := fmt.pretty (width := 100000)
      match declared with
      | none => return { statement, axioms }
      | some text =>
        match ← statementMatches env opens text info.type with
        | .ok same => return { statement, statementMatches := some same, axioms }
        | .error e => return { statement, axioms, errors := [e] }
  catch e =>
    return { errors := [s!"failed to load module '{moduleName}': {e}"] }

def main (argv : List String) : IO UInt32 := do
  let args ← match parseArgs argv {} with
    | .ok a => pure a
    | .error e => throw (IO.userError s!"{e}\nusage: airas-report --module <M> --decl <d> [--mode sanity|full] [--build-log <path>] [--out <path>]")
  if args.module.isEmpty || args.decl.isEmpty then
    throw (IO.userError "--module and --decl are required")
  if args.mode != "sanity" && args.mode != "full" then
    throw (IO.userError s!"Lean runs have no '{args.mode}' stage: use sanity (the statement type-checks, sorry allowed) or full (a sorry-free proof)")

  let log ← match args.buildLog with
    | some path => readFileOrEmpty path
    | none => pure ""
  let buildErrors := logLines log "error"
  let warnings := logLines log "warning"

  -- Import even after a failed build: the module may have built before the
  -- failing change, and an unrelated module's failure must not hide this one.
  enableInitializers
  let opens := (args.opens.splitOn ",").map trimmed |>.filter (· ≠ "") |>.map String.toName
  let (declared, recordErrors) ← match args.record, args.runId with
    | some record, some runId =>
      match ← declaredStatement record runId with
      | .ok declared => pure (declared, [])
      | .error e => pure (none, [e])
    | _, _ => pure (none, [])
  let inspection ← inspect args.module args.decl opens declared
  let errors := buildErrors ++ recordErrors ++ inspection.errors

  let report := Json.mkObj [
    ("commit", match ← commitSha with | some sha => Json.str sha | none => Json.null),
    ("toolchain", Json.str (trimmed (← readFileOrEmpty args.toolchainFile))),
    ("mathlib_rev", Json.str (← manifestMathlibRev args.manifestFile)),
    ("module", Json.str args.module),
    ("decl", Json.str args.decl),
    ("mode", Json.str args.mode),
    ("statement", Json.str inspection.statement),
    ("statement_matches", match inspection.statementMatches with
      | some b => Json.bool b | none => Json.null),
    ("axioms", Json.arr (inspection.axioms.map Json.str)),
    ("errors", Json.arr (errors.toArray.map Json.str)),
    ("warnings", Json.arr (warnings.toArray.map Json.str))
  ]
  if let some dir := (System.FilePath.mk args.out).parent then
    IO.FS.createDirAll dir
  IO.FS.writeFile args.out (report.pretty ++ "\n")
  IO.println s!"=== [AIRAS-REPORT] {args.out}"
  IO.println (report.pretty)

  let usesSorry := inspection.axioms.contains "sorryAx"
  if !errors.isEmpty then
    IO.eprintln s!"airas-report: {args.decl} did not build ({errors.length} error(s))"
    return 1
  if inspection.statementMatches == some false then
    IO.eprintln s!"airas-report: {args.decl} is not the statement the record declares for this run"
    return 1
  if args.mode == "full" && usesSorry then
    IO.eprintln s!"airas-report: {args.decl} uses sorry; a full run needs a complete proof"
    return 1
  return 0
