"""1 インスタンスを公式 Controller で解かせる。公式の履歴はクラス属性なので 1 件 1 プロセス。"""

import ctypes
import json
import os
import re
import sys
import sysconfig
import time
from pathlib import Path

# libroadrunner は libpython を動的に探すので、ローダのパスに無い環境（uv 管理の Python）では先読みする
_libpython = f"{sysconfig.get_config_var('LIBDIR')}/libpython3.11.so.1.0"
if os.path.exists(_libpython):
    ctypes.CDLL(_libpython, mode=ctypes.RTLD_GLOBAL)

import openai  # noqa: E402
from openai import OpenAI  # noqa: E402
from scigym.api import LLM  # noqa: E402
from scigym.controller import Controller  # noqa: E402

BUDGET_EXCEEDED = 42  # 予算超過（HTTP 402）。RIKYU では起きない想定だが main.py は run 全体を止める
CONTEXT_OVERFLOW = 43  # 会話が文脈長を超えた。main.py はやり直さず「提出に至らなかった件」として数える
MAX_RETRIES = 360  # 5xx や接続断は 60 秒おきに最大 6 時間呼び直す。推論 API は数時間止まることがあり、試行を落とすと反復が無駄になる
CONTEXT_WINDOW = 262144  # 既定。run の yaml の context_window（サーバーの /v1/models の max_model_len）で上書きする
# サーバー側の reasoning parser が思考を分離し損ねたときの保険。本文先頭の <think>…</think> か、思考の見出しで始まる節を除く
THINKING_PREFIX = re.compile(r"\A\s*(?:<think>.*?</think>|(?:Here's a thinking process|Thinking Process|Let me think)[^\n]*\n.*?)(?=\n#|\n```|\Z)", re.S | re.I)


class OpenAICompatible(LLM):
    """公式の scigym.agent.GPT と同じ手順で、OpenAI 互換エンドポイントを呼ぶ。"""

    base_url_file = None  # NIM サーバーの接続先を書いたファイル。サーバーの job が別ノードで立ち直ると接続先が変わるので、接続断のたびに読み直す

    def initialize(self, base_url):
        self.base_url = base_url
        self._connect()
        self.messages = [{"role": "system", "content": self.system_prompt}]

    def _connect(self):
        if self.base_url_file:
            self.base_url = Path(self.base_url_file).read_text().strip()
        # NIM は認証なし（鍵の環境変数が無ければダミー）。15 tok/s のモデルは 1 応答に 10 分を超えるので timeout は 1 時間
        self.client = OpenAI(api_key=os.environ.get("RIKYU_API_KEY", "none"), base_url=self.base_url, max_retries=1, timeout=3600)

    def add_message(self, role, content):
        self.messages.append({"role": role, "content": content})

    def get_messages(self):
        return self.messages

    def get_response(self, user_message):
        self.add_message("user", user_message)
        max_tokens = self.max_length
        for attempt in range(MAX_RETRIES):
            try:
                response = self.client.chat.completions.create(
                    model=self.model_name,
                    messages=self.messages,
                    max_tokens=max_tokens,
                    temperature=self.temperature,
                )
            except (openai.APIConnectionError, openai.APITimeoutError) as exc:
                if attempt == MAX_RETRIES - 1:
                    raise
                print(f"connection error ({type(exc).__name__}); retry {attempt + 1} after 60s", flush=True)
                time.sleep(60)
                try:
                    self._connect()
                except FileNotFoundError:  # サーバーの job が立ち直るまで接続先ファイルは無い
                    pass
                continue
            except openai.APIStatusError as exc:
                if exc.status_code == 402:
                    sys.exit(BUDGET_EXCEEDED)
                if exc.status_code == 400 and any(w in str(exc).lower() for w in ("context", "maximum", "too long", "max_tokens")):
                    print(f"context overflow after {len(self.messages)} messages: {exc}", flush=True)
                    sys.exit(CONTEXT_OVERFLOW)
                if exc.status_code == 429 and attempt < MAX_RETRIES - 1:  # 鍵の同時要求数の上限（throttling）。空くまで待つ
                    print(f"rate limited (429); retry {attempt + 1} after 60s", flush=True)
                    time.sleep(60)
                    continue
                if exc.status_code < 500 or attempt == MAX_RETRIES - 1:
                    raise
                print(f"gateway {exc.status_code}; retry {attempt + 1} after 60s", flush=True)  # 上流の一時的な不調は待って呼び直す
                time.sleep(60)
                continue
            choice = response.choices[0]
            text = choice.message.content
            if isinstance(text, str) and len(text) > 0:
                break
            usage = response.usage.model_dump() if response.usage else None
            print(f"empty response: finish_reason={choice.finish_reason} max_tokens={max_tokens} usage={usage}", flush=True)
            with open(self.empty_log, "a") as f:  # 本文が空の生応答を残す（gateway の reasoning 解析のずれを疑っている）
                f.write(json.dumps(response.model_dump(), ensure_ascii=False) + "\n")
            if choice.finish_reason == "length":  # thinking で使い切った。文脈長に収まる範囲で上限を上げて呼び直す
                prompt_tokens = usage["prompt_tokens"] if usage else 0
                new_max = min(max_tokens * 2, 131072, self.context_window - prompt_tokens - 1024)
                if new_max <= max_tokens:
                    print(f"context overflow: prompt {prompt_tokens} tokens leaves no room to grow max_tokens", flush=True)
                    sys.exit(CONTEXT_OVERFLOW)
                max_tokens = new_max
            else:  # 本文が空で reasoning 側で終わっている応答は、コードブロックまで reasoning に入っている。その文を本文として返す
                reasoning = getattr(choice.message, "reasoning_content", None) or getattr(choice.message, "reasoning", None)
                if isinstance(reasoning, str) and len(reasoning) > 0:
                    text = reasoning
                    break
        assert isinstance(text, str) and len(text) > 0, "empty response"
        stripped = THINKING_PREFIX.sub("", text, count=1).lstrip()
        if stripped and stripped != text:  # 思考が本文に混じっていた応答。件数は論文で報告する
            self.n_thinking_in_content += 1
            text = stripped
        self.add_message("assistant", text)
        usage = response.usage
        self.n_calls += 1
        prompt_tokens = usage.prompt_tokens if usage else 0
        self.max_prompt_tokens = max(self.max_prompt_tokens, prompt_tokens)
        self.input_total_tokens += prompt_tokens
        self.output_total_tokens += usage.completion_tokens if usage else 0
        self._write_tokens()  # 文脈超過で途中終了しても呼び出し数と最大文脈長が残るよう、毎回書く
        return text, {}

    def _write_tokens(self):
        self.tokens_path.write_text(json.dumps({
            "input_tokens": self.input_total_tokens, "output_tokens": self.output_total_tokens,
            "n_calls": self.n_calls, "max_prompt_tokens": self.max_prompt_tokens, "n_thinking_in_content": self.n_thinking_in_content,
        }))


def main():
    cfg = json.loads(sys.argv[1])
    out = Path(cfg["out_dir"])
    out.mkdir(parents=True, exist_ok=True)
    controller = Controller(
        path_to_sbml_cfg=cfg["instance_dir"],
        max_iterations=cfg["max_iterations"],
        test_memorize=False,
        output_directory=str(out),
        experiment_actions_path="prompts/experiment_actions_perturb.md",
        customized_functions_path="prompts/customized_functions_sim.md",
        eval_debug_rounds=cfg["eval_debug_rounds"],
        temperature=cfg["temperature"],
    )
    OpenAICompatible.empty_log = out / "empty_responses.jsonl"
    OpenAICompatible.tokens_path = out / "tokens.json"
    OpenAICompatible.n_calls = OpenAICompatible.max_prompt_tokens = OpenAICompatible.n_thinking_in_content = 0
    OpenAICompatible.base_url_file = cfg.get("base_url_file")
    OpenAICompatible.context_window = cfg.get("context_window") or CONTEXT_WINDOW
    llm = OpenAICompatible(
        model_name=cfg["model"],
        api_key="",
        system_prompt=controller._create_system_prompt(),
        temperature=cfg["temperature"],
        max_length=cfg["max_tokens"],
        base_url=cfg["base_url"],
    )
    controller.run_benchmark(model=llm)
    llm._write_tokens()


if __name__ == "__main__":
    main()
