"""airas-eval（scigym_small / scigym_large）のレポートをそのまま metrics.json に写し、実験側が数えたトークン数と反復数を添える。"""

import json
import sys
from pathlib import Path

import yaml


def main():
    cfg = {k: yaml.safe_load(v) for k, _, v in (a.partition("=") for a in sys.argv[1:])}
    for run_id in cfg["run_ids"]:
        run_dir = Path(cfg["results_dir"]) / run_id
        run_cfg = yaml.safe_load(open(f"config/run/{run_id}.yaml"))
        split = run_cfg["split"]
        report = json.loads((run_dir / "evaluation" / f"scigym_{split}.json").read_text())
        # 文脈の表で使う run の設定値（独立変数の上限反復と、サーバーの文脈長）も metrics.json に写す
        conditions = {"max_iterations": run_cfg["max_iterations"], "context_window": run_cfg["context_window"]}
        metrics = {**report["metrics"], **report["inputs_summary"], **json.loads((run_dir / "tokens.json").read_text()), **conditions}
        (run_dir / "metrics.json").write_text(json.dumps(metrics, indent=1))
        print(run_id, json.dumps(metrics))


if __name__ == "__main__":
    main()
