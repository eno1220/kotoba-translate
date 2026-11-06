"""One local model per process; stdin/stdout are a private JSON-lines protocol."""
import contextlib
from collections import deque
import json
import os
from pathlib import Path
import sys
import time
import traceback

from translation_chunks import CONTEXT_LIMIT, output_separator, plan_chunks, split_again

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


def translate(r, model, tokenizer, generate, sampler, clear_cache, started, load_seconds):
    """Generate with a fresh KV cache per attempt; commit only complete chunks.

    Draft events let the native UI stream provisional text. API clients receive
    only committed deltas, so a length retry never leaks duplicated/truncated text.
    """
    auto_split = r.get("auto_split", True)
    if not isinstance(auto_split, bool):
        raise ValueError("auto_splitはtrueまたはfalseで指定してください。")
    max_tokens = r["max_tokens"]
    if auto_split:
        emit("planning")
    chunks = deque(plan_chunks(r, tokenizer, build_prompt) if auto_split else [r["text"]])
    completed = generation_tokens = prompt_tokens = 0
    generation_seconds = prompt_seconds = 0.0
    previous = ""
    finish_reason = "stop"
    while chunks:
        text = chunks.popleft()
        if auto_split and not text.strip():
            emit("delta", text=text)
            previous = text[-1:]
            completed += 1
            continue
        leading = text[:len(text) - len(text.lstrip())] if auto_split else ""
        trailing = text[len(text.rstrip()):] if auto_split else ""
        source = text.strip() if auto_split else text
        prompt = build_prompt(dict(r, text=source), tokenizer.bos_token or "")
        tokens = tokenizer.encode(prompt, add_special_tokens=False)
        if len(tokens) + max_tokens > CONTEXT_LIMIT:
            if auto_split:
                chunks.extendleft(reversed(split_again(text)))
                continue
            raise ValueError(f"入力 {len(tokens)} + Max tokens {max_tokens} が32768を超えています。原文・Context・辞書を短くするか、自動分割を有効にしてください。")
        emit("chunk", chunk=completed + 1, chunks=completed + len(chunks) + 1)
        emit("prefill", current=0, total=len(tokens), load_seconds=load_seconds)
        last = None
        pending = []
        last_emit = 0.0

        def progress(current, total):
            emit("prefill", current=current, total=total)

        try:
            with contextlib.closing(generate(
                model, tokenizer, tokens, max_tokens=max_tokens, sampler=sampler,
                prompt_progress_callback=progress,
            )) as stream:
                for last in stream:
                    pending.append(last.text)
                    now = time.perf_counter()
                    if now - last_emit >= 0.05:
                        emit("draft" if auto_split else "delta",
                             text=leading + "".join(pending) if auto_split else "".join(pending),
                             tokens=generation_tokens + last.generation_tokens, tps=last.generation_tps)
                        if not auto_split:
                            pending.clear()
                        last_emit = now
        finally:
            # Even a failed/discarded attempt must release its private KV cache.
            clear_cache()

        count = last.generation_tokens if last else 0
        generation_tokens += count
        prompt_tokens += len(tokens)
        if last and last.generation_tps > 0:
            generation_seconds += count / last.generation_tps
        if last and last.prompt_tps > 0:
            prompt_seconds += len(tokens) / last.prompt_tps
        finish_reason = last.finish_reason if last else "stop"
        if auto_split:
            if finish_reason == "length":
                emit("draft", text="", tokens=generation_tokens)
                chunks.extendleft(reversed(split_again(text)))
                continue
            translated = leading + "".join(pending).strip() + trailing
            separator = output_separator(previous, translated[:1], r["target"])
            emit("delta", text=separator + translated, tokens=generation_tokens,
                 tps=generation_tokens / generation_seconds if generation_seconds else 0)
            if translated:
                previous = translated[-1]
        elif pending:
            emit("delta", text="".join(pending), tokens=generation_tokens)
        completed += 1

    emit("done", elapsed=time.perf_counter() - started,
         load_seconds=load_seconds, prompt_tokens=prompt_tokens, tokens=generation_tokens,
         tps=generation_tokens / generation_seconds if generation_seconds else 0,
         prompt_tps=prompt_tokens / prompt_seconds if prompt_seconds else 0,
         finish_reason=finish_reason, chunk=completed, chunks=completed)


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
            r["max_tokens"] = max_tokens
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
            translate(r, model, tokenizer, stream_generate, make_sampler(temp=temperature),
                      mx.clear_cache, started, load_seconds)
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            emit("error", message=str(error))


if __name__ == "__main__":
    main()
