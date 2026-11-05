"""One local model per process; stdin/stdout are a private JSON-lines protocol."""
import contextlib
import json
import os
from pathlib import Path
import sys
import time
import traceback

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
PROTOCOL = sys.stdout
sys.stdout = sys.stderr  # Model/runtime diagnostics must never corrupt the protocol.

LANGUAGES = set("ja en zh-hans zh-hant ko ar az be bg bn ca ceb de es et eu fa fr gu he hi hr hu hy id it jv ka kk km lt lv ml mr ms my ne nl pa pl ru si sk sl sr sw ta te th tl ur uz vi".split())
STOP = ("<|plamo:tag|>", "<|plamo:bos|>")


def emit(event, **values):
    PROTOCOL.write(json.dumps(dict(event=event, **values), ensure_ascii=False) + "\n")
    PROTOCOL.flush()


def checked_text(value, label, allow_empty=False):
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise ValueError(f"{label}を入力してください。")
    if "<|plamo:" in value:
        raise ValueError(f"{label}に予約トークン <|plamo: は使用できません。")
    return value


def build_prompt(r, bos):
    source = r.get("source", "")
    target = r["target"]
    if target not in LANGUAGES or (source and source not in LANGUAGES):
        raise ValueError("未対応の言語です。")
    text = checked_text(r["text"], "原文")
    context = checked_text(r.get("context", ""), "Context", True)
    form = r.get("form", "")
    if form and (form not in ("plain", "polite") or target != "ja"):
        raise ValueError("文体は日本語出力の常体・敬体のみ指定できます。")
    prompt = bos + "<|plamo:tag|>dataset<|plamo:msg|>translation"
    if context:
        prompt += "<|plamo:tag|>context<|plamo:msg|>" + context
    glossary = r.get("glossary", [])
    if glossary:
        prompt += "<|plamo:tag|>glossary"
        for term in glossary:
            prompt += "<|plamo:index|>" + checked_text(term["source"], "辞書の原語")
            prompt += "<|plamo:item|>" + checked_text(term["target"], "辞書の訳語")
    prompt += "<|plamo:tag|>input"
    if source:
        prompt += "<|plamo:key|>lang<|plamo:val|>" + source
    prompt += "<|plamo:msg|>" + text
    prompt += "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + target
    if form:
        prompt += "<|plamo:key|>form<|plamo:val|>" + form
    return prompt + "<|plamo:msg|>"


def main():
    model = tokenizer = None
    loaded_path = None
    for line in sys.stdin:
        try:
            r = json.loads(line)
            started = time.perf_counter()
            path = Path(r["model"]).expanduser().resolve(strict=True)
            if not path.is_dir():
                raise ValueError("モデルのディレクトリを指定してください。")
            config = json.loads((path / "config.json").read_text())
            if config.get("model_type") != "plamo3" or not config.get("model_file"):
                raise ValueError("PLaMo 3 TranslateのMLXモデルを指定してください。")
            max_tokens = int(r["max_tokens"])
            temperature = float(r["temperature"])
            if not 1 <= max_tokens < 32768 or not 0 <= temperature <= 2:
                raise ValueError("Max tokensは1〜32767、Temperatureは0〜2で指定してください。")
            if loaded_path != path:
                emit("loading")
                # Switching paths is normally handled by restarting the process in Swift.
                from mlx_lm import load
                model, tokenizer = load(str(path), trust_remote_code=True,
                                        tokenizer_config={"trust_remote_code": True})
                for stop in STOP:
                    tokenizer.add_eos_token(stop)
                loaded_path = path
            load_seconds = time.perf_counter() - started
            from mlx_lm import stream_generate
            from mlx_lm.sample_utils import make_sampler
            import mlx.core as mx
            prompt = build_prompt(r, tokenizer.bos_token or "")
            tokens = tokenizer.encode(prompt, add_special_tokens=False)
            if len(tokens) + max_tokens > 32768:
                raise ValueError(f"入力 {len(tokens)} + Max tokens {max_tokens} が32768を超えています。原文・Context・辞書を短くしてください。")
            emit("prefill", current=0, total=len(tokens), load_seconds=load_seconds)
            last = None
            output = ""
            sent_length = 0
            last_emit = 0.0
            def progress(current, total):
                emit("prefill", current=current, total=total)
            # Batching UI updates to 20 Hz keeps decoding and the main thread inexpensive.
            with contextlib.closing(stream_generate(
                model, tokenizer, tokens, max_tokens=max_tokens,
                sampler=make_sampler(temp=temperature),
                prompt_progress_callback=progress,
            )) as stream:
                for last in stream:
                    output += last.text
                    now = time.perf_counter()
                    if now - last_emit >= 0.05:
                        emit("delta", text=output[sent_length:], tokens=last.generation_tokens,
                             tps=last.generation_tps)
                        sent_length = len(output)
                        last_emit = now
            if len(output) > sent_length:
                emit("delta", text=output[sent_length:])
            emit("done", elapsed=time.perf_counter() - started,
                 load_seconds=load_seconds, prompt_tokens=len(tokens),
                 tokens=last.generation_tokens if last else 0,
                 tps=last.generation_tps if last else 0,
                 prompt_tps=last.prompt_tps if last else 0,
                 finish_reason=last.finish_reason if last else "stop")
            mx.clear_cache()
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            emit("error", message=str(error))


if __name__ == "__main__":
    main()
