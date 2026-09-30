"""1 つの run（= 1 モデル × 1 split × 1 反復上限）で SciGym を解かせ、評価層 scigym_<split> の入力ファイルを書く。"""

import gzip
import json
import shutil
import subprocess
import tarfile
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import yaml

BUDGET_EXCEEDED = 42
CONTEXT_OVERFLOW = 43
THINKING_EXHAUSTED = 44


def cli_args():
    """hydra 形式の key=value を読む。hydra / omegaconf は scigym が固定する petab の antlr 版と衝突する"""
    return {k: yaml.safe_load(v) for k, _, v in (a.partition("=") for a in sys.argv[1:])}


def run_instance(cfg, run_dir, instance):
    out = run_dir / "instances" / instance.name
    if (out / "evaluation.json").exists():
        return 0
    if (out / "context_overflow").exists() or (out / "thinking_exhausted").exists():
        return 0  # 文脈長を超えた件、思考が終わらなかった件。やり直さず「提出なし」として不完全モデルで採点する
    if (out / "stdout.txt").exists() and (out / "stdout.txt").read_text().count("killed after") >= 3:
        return 0  # 3 試行とも上限で打ち切られた件。公式の「有効な提出なし」と同じく不完全モデルで採点する
    args = {
        "instance_dir": str(instance),
        "out_dir": str(out),
        "model": cfg.run_model,
        "base_url": cfg.base_url,
        "max_iterations": 2 if cfg.mode == "sanity" else cfg.max_iterations,
        "eval_debug_rounds": cfg.eval_debug_rounds,
        "temperature": cfg.temperature,
        "max_tokens": cfg.max_tokens,
        "base_url_file": getattr(cfg, "base_url_file", None),
        "context_window": getattr(cfg, "context_window", None),
    }
    out.mkdir(parents=True, exist_ok=True)
    log_path = out / "stdout.txt"
    with open(log_path, "a") as log:
        proc = subprocess.Popen([sys.executable, "-m", "src.train", json.dumps(args)], stdout=log, stderr=subprocess.STDOUT)
        started = time.time()
        while proc.poll() is None:
            time.sleep(30)
            # LLM のコードや提出モデルの評価が ODE の C ライブラリ内で止まると公式の 3 分制限（SIGALRM）が効かない。
            # Controller は反復ごとに出力するので、出力が止まったままの試行は打ち切って最初からやり直す
            # 再試行は前の試行が終わって何時間も後に始まるので、基準は前試行の最終出力ではなく今回の開始時刻
            silent = time.time() - max(log_path.stat().st_mtime, started)
            if time.time() - started > cfg.instance_timeout or silent > cfg.stall_timeout:
                proc.kill()
                proc.wait()
                print(f"[{instance.name}] killed after {int(time.time() - started)}s ({int(silent)}s without output)", file=log)
                return 1
    if proc.returncode == CONTEXT_OVERFLOW:
        (out / "context_overflow").touch()
    if proc.returncode == THINKING_EXHAUSTED:
        (out / "thinking_exhausted").touch()
    if not (out / "evaluation.json").exists():  # 失敗した run の作業ディレクトリは残らないので原因を標準出力へ
        print(f"[{instance.name}] no evaluation.json; log tail:", *(out / "stdout.txt").read_text().splitlines()[-25:], sep="\n  ")
    if (out / "evaluation.json").exists() or (out / "context_overflow").exists() or (out / "thinking_exhausted").exists():
        checkpoint(run_dir, instance.name)
    return proc.returncode


def checkpoint(run_dir, name):
    """終わった件を 1 件 1 書庫で残す。job が 4 日上限で打ち切られても、集めた書庫から続きを実行できる"""
    out = run_dir / "instances" / name
    shutil.rmtree(out / "codes", ignore_errors=True)  # 反復ごとのコードは chat_history.yaml に含まれる
    (out / "chat_history_readable.txt").unlink(missing_ok=True)
    (run_dir / "checkpoints").mkdir(parents=True, exist_ok=True)
    with tarfile.open(run_dir / "checkpoints" / f"{name}.tar.gz", "w:gz") as tar:
        tar.add(out, arcname=f"instances/{name}")


def iterations_used(out):
    """提出までに使った反復数。chat_history.yaml の Iteration 0 は初期プロンプトなので除く"""
    history = json.loads((out / "chat_history.yaml").read_text())
    return max(len(history) - 1, 0)


def main():
    cli = cli_args()
    run_id = cli["run"]
    cfg = yaml.safe_load(open("config/config.yaml"))
    cfg.update(cli)
    cfg["run"] = yaml.safe_load(open(f"config/run/{run_id}.yaml"))
    # 生成が遅いモデルは run の yaml で並列度と試行上限を上書きする（API はバッチ処理で 1 要求あたりの速度が落ちない）
    cfg.update({k: v for k, v in cfg["run"].items() if k in ("max_iterations", "workers", "instance_timeout", "base_url_file", "context_window")})
    split = cfg["run"]["split"]
    cfg = SimpleNamespace(**cfg, run_model=cfg["run"]["model"], data_dir=f"{cfg['data_root']}/{split}", task=f"scigym_{split}")
    run_dir = Path(cfg.results_dir) / run_id
    instances = sorted(p for p in Path(cfg.data_dir).iterdir() if p.is_dir())
    if cfg.mode == "sanity":
        instances = instances[:1]
    elif cfg.mode == "pilot":
        instances = instances[:: max(len(instances) // 10, 1)][:10]
    stage = cfg.mode.upper()
    # 失敗した前 run の件ごとの出力から続きを実行する。Seyval は実行前に .research/results を空にするので resume/ に置く
    if not (run_dir / "instances").exists():
        run_dir.mkdir(parents=True, exist_ok=True)
        # 打ち切った前 run の件ごとの書庫。リポジトリの resume/ か、計算機上の resume_root（書庫が大きく git に置かないとき）
        sources = [Path("resume", run_id)] + ([Path(cfg.resume_root, run_id)] if getattr(cfg, "resume_root", None) else [])
        for archive in sorted(a for src in sources for a in src.glob("**/*.tar.gz")):
            with tarfile.open(archive) as tar:
                tar.extractall(run_dir)
    # API エラーで evaluation.json が出なかった件は 2 回までやり直す。予算超過（402）は即座に run を止める
    for _ in range(3):
        with ThreadPoolExecutor(cfg.workers) as pool:
            codes = list(pool.map(lambda p: run_instance(cfg, run_dir, p), instances))
        if BUDGET_EXCEEDED in codes:
            print(f"{stage}_VALIDATION: FAIL reason=budget_exceeded")
            sys.exit(1)
    submitted, tokens = {}, {"input_tokens": 0, "output_tokens": 0, "n_calls": 0, "n_thinking_in_content": 0, "max_prompt_tokens": 0}
    iterations, n_overflow, n_exhausted = [], 0, 0
    for instance in instances:
        out = run_dir / "instances" / instance.name
        if (out / "context_overflow").exists():
            n_overflow += 1
        if (out / "thinking_exhausted").exists():
            n_exhausted += 1
        # 文脈超過した件の呼び出し数・最大プロンプト長も文脈の表に数える（tokens.json は超過時にも書く）
        if (out / "tokens.json").exists():
            for k, v in json.loads((out / "tokens.json").read_text()).items():
                tokens[k] = max(tokens[k], v) if k == "max_prompt_tokens" else tokens.get(k, 0) + v
        if not (out / "evaluation.json").exists():
            continue  # 文脈超過か、3 試行とも終わらなかった件: 提出無しとして評価層に渡す
        submitted[instance.name] = (out / "final_model.xml").read_text() if (out / "final_model.xml").exists() else None
        iterations.append(iterations_used(out))
    max_iterations = 2 if cfg.mode == "sanity" else cfg.max_iterations
    tokens["mean_prompt_tokens"] = tokens["input_tokens"] / tokens["n_calls"] if tokens["n_calls"] else 0.0  # 1 呼び出しあたりの平均文脈長
    tokens |= {
        "mean_iterations": sum(iterations) / len(iterations) if iterations else 0.0,
        "n_early_submit": sum(i < max_iterations for i in iterations),  # 上限を使い切らずに自ら提出した件
        "n_context_overflow": n_overflow,
        "n_thinking_exhausted": n_exhausted,  # 思考だけで出力上限を使い切る応答が 3 サンプル続いて提出に至らなかった件
        "n_not_finished": len(instances) - len(submitted),
    }
    (run_dir / "eval_inputs").mkdir(parents=True, exist_ok=True)
    # 評価入力は gzip で書く（large は参照 SBML と提出 SBML で 100 MB 近くなり、取り込みの上限 50 MB を超える）
    with gzip.open(run_dir / "eval_inputs" / f"{cfg.task}.json.gz", "wt", encoding="utf-8") as f:
        f.write(json.dumps({"instances": [{
        "id": p.name,
        "reference_sbml": (p / "truth.xml").read_text(),
        "incomplete_sbml": (p / "partial.xml").read_text(),
        "reference_sedml": (p / "truth.sedml").read_text(),
        "submitted_sbml": submitted.get(p.name),
    } for p in instances]}))
    (run_dir / "tokens.json").write_text(json.dumps(tokens))
    # 取り込みは 1 ファイル 1 API 呼び出しなので、件ごとの出力は 1 つの書庫にまとめる（GitHub の secondary rate limit 対策）
    with tarfile.open(run_dir / "instances.tar.gz", "w:gz") as tar:
        tar.add(run_dir / "instances", arcname="instances")
    shutil.rmtree(run_dir / "instances")
    shutil.rmtree(run_dir / "checkpoints", ignore_errors=True)  # 全件そろったので件ごとの書庫は不要
    print(f"{stage}_VALIDATION_SUMMARY: {json.dumps({'n_instances': len(instances), 'n_with_submission': sum(v is not None for v in submitted.values()), **tokens})}")
    print(f"{stage}_VALIDATION: PASS")


if __name__ == "__main__":
    main()
