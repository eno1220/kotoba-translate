"""Focused checks using a deterministic tokenizer/generator; no model is loaded."""
import random
from pathlib import Path
import sys
import time
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources/KotobaTranslate/Resources"))
stdout = sys.stdout
import worker
sys.stdout = stdout
from translation_chunks import natural_cut, output_separator, plan_chunks, safe_cut, split_again
from repetition_guard import RepetitionGuard


class Tokenizer:
    bos_token = "<|plamo:bos|>"

    def encode(self, text, add_special_tokens=False):
        assert not add_special_tokens
        return list(text)


def request(text, **options):
    return dict(text=text, source="en", target="ja", form="polite",
                context="Technical documentation", glossary=[{"source": "cat", "target": "猫"}],
                max_tokens=80, temperature=0, **options)


class ChunkChecks(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.old_emit = worker.emit
        worker.emit = lambda event, **values: self.events.append(dict(event=event, **values))
        self.addCleanup(setattr, worker, "emit", self.old_emit)

    def run_translation(self, r, truncate_above=None, force_length=False, repeat_above=None):
        self.attempts = []
        self.cleared = 0
        self.closed = 0
        self.generated = 0

        def clear():
            self.cleared += 1

        def generate(model, tokenizer, tokens, max_tokens, sampler, prompt_progress_callback):
            prompt = "".join(tokens)
            self.assertLessEqual(len(tokens) + max_tokens, 32768)
            self.assertEqual(prompt.count(tokenizer.bos_token), 1)
            self.assertIn("dataset<|plamo:msg|>translation", prompt)
            self.assertIn(r["context"], prompt)
            self.assertIn("<|plamo:val|>polite", prompt)
            source = prompt.split("<|plamo:tag|>input", 1)[1].split("<|plamo:msg|>", 1)[1].split("<|plamo:tag|>output", 1)[0]
            self.attempts.append(source)
            prompt_progress_callback(len(tokens), len(tokens))
            length = force_length or (truncate_above is not None and len(source) > truncate_above)
            output = "DISCARDED" if length else source
            if repeat_above is not None and len(source) > repeat_above:
                output = ("LOOP!" * max_tokens)[:max_tokens]
                length = True
            try:
                for index, char in enumerate(output, 1):
                    self.generated += 1
                    yield SimpleNamespace(text=char, token=ord(char), generation_tokens=index, generation_tps=10,
                                          prompt_tps=100, finish_reason=("length" if length else "stop")
                                          if index == len(output) else None)
            finally:
                self.closed += 1

        worker.translate(r, None, Tokenizer(), generate, None, clear, time.perf_counter(), 0.25)
        return "".join(e["text"] for e in self.events if e["event"] == "delta")

    def test_paragraph_sentence_and_fence_boundaries(self):
        text = "First paragraph.\n\nSecond sentence. Another sentence continuing."
        self.assertEqual(natural_cut(text, 33), len("First paragraph.\n\n"))
        text = "First sentence. Another sentence continuing with more words."
        self.assertEqual(natural_cut(text, 29), len("First sentence. "))
        text = "Introduction\n\n```python\nprint('hello')\n```\n\nFollowing paragraph."
        cut = natural_cut(text, 26)
        self.assertEqual(cut, len("Introduction\n\n"))

    def test_lossless_partition_and_exact_budgets(self):
        rng = random.Random(73)
        units = ["paragraph\n\n", "word ", "文です。", "e\u0301", "👨‍👩‍👧‍👦", "🇯🇵", "👍🏽", "\t"]
        for _ in range(40):
            text = "  " + "".join(rng.choice(units) for _ in range(40)) + "\n"
            r = request(text)
            chunks = plan_chunks(r, Tokenizer(), worker.build_prompt)
            self.assertEqual("".join(chunks), text)
            offset = 0
            for chunk in chunks:
                self.assertTrue(chunk)
                if chunk.strip():
                    self.assertLessEqual(len(Tokenizer().encode(chunk)), int(r["max_tokens"] * 0.4))
                    prompt = worker.build_prompt(dict(r, text=chunk), Tokenizer.bos_token)
                    self.assertLessEqual(len(prompt) + r["max_tokens"], 32768)
                offset += len(chunk)
                self.assertEqual(safe_cut(text, offset), offset)

    def test_context_window_can_force_smaller_chunks(self):
        r = request("a" * 90)
        overhead = len(worker.build_prompt(dict(r, text="x", context="x"), Tokenizer.bos_token)) - 2
        r["context"] = "x" * (32768 - r["max_tokens"] - overhead - 7)
        chunks = plan_chunks(r, Tokenizer(), worker.build_prompt)
        self.assertGreater(len(chunks), 1)
        for chunk in chunks:
            self.assertLessEqual(len(worker.build_prompt(dict(r, text=chunk), Tokenizer.bos_token)) + r["max_tokens"], 32768)
        r["context"] += "x" * 100
        with self.assertRaisesRegex(ValueError, "上限に収まりません"):
            plan_chunks(r, Tokenizer(), worker.build_prompt)

    def test_whole_input_validation_precedes_partition(self):
        r = request("x" * 100 + "<|plamo:bos|>" + "x" * 100)
        with self.assertRaisesRegex(ValueError, "予約トークン"):
            plan_chunks(r, Tokenizer(), worker.build_prompt)

    def test_complete_chunks_preserve_layout_and_settings(self):
        text = "  first paragraph.\n\n" + "長い文です。" * 30 + "\n\nlast paragraph.  "
        output = self.run_translation(request(text))
        self.assertEqual(output, text)
        self.assertGreater(len(self.attempts), 1)
        self.assertEqual(self.cleared, len(self.attempts))
        self.assertTrue(any(e["event"] == "draft" for e in self.events))
        done = self.events[-1]
        self.assertEqual(done["event"], "done")
        self.assertEqual(done["finish_reason"], "stop")
        self.assertEqual(done["tokens"], sum(map(len, self.attempts)))
        self.assertEqual(done["load_seconds"], 0.25)

    def test_truncated_attempt_is_replaced_without_leaking_to_api(self):
        text = "one sentence. another sentence.\n\n最後の文です。"
        output = self.run_translation(request(text), truncate_above=9)
        self.assertEqual(output, text)
        self.assertNotIn("DISCARDED", output)
        self.assertGreater(len(self.attempts), self.events[-1]["chunks"])
        self.assertEqual(self.cleared, len(self.attempts))
        self.assertTrue(any(e["event"] == "draft" and e["text"] == "" for e in self.events))
        self.assertGreater(self.events[-1]["tokens"], len(text.strip()))
        self.assertTrue(any(e["event"] == "retry" and e["reason"] == "length" for e in self.events))

    def test_repetition_stops_early_and_retries_without_leaking(self):
        r = request("first sentence. second sentence.\n\nlast sentence.")
        r["max_tokens"] = 4096
        output = self.run_translation(r, repeat_above=16)
        self.assertEqual(output, r["text"])
        self.assertNotIn("LOOP!", output)
        self.assertEqual(self.closed, len(self.attempts))
        self.assertEqual(self.cleared, len(self.attempts))
        self.assertEqual(self.generated, self.events[-1]["tokens"])
        retries = [e for e in self.events if e["event"] == "retry"]
        self.assertTrue(retries)
        self.assertTrue(all(e["reason"] == "repetition" for e in retries))
        self.assertEqual(self.events[-1]["retries"], len(retries))
        self.assertLess(self.generated, 300 * len(self.attempts))
        self.assertEqual(self.events[-1]["finish_reason"], "stop")

    def test_minimal_fragment_repetition_is_an_explicit_error(self):
        r = request("x")
        r["max_tokens"] = 4096
        with self.assertRaisesRegex(ValueError, "最小の原文単位でも繰り返し"):
            self.run_translation(r, repeat_above=0)
        self.assertEqual(self.closed, 1)
        self.assertEqual(self.cleared, 1)
        self.assertFalse(any(e["event"] in {"delta", "done"} for e in self.events))

    def test_repetition_guard_cycles_and_bounded_memory(self):
        for period in [1, 2, 5, 31, 32, 64, 127, 256]:
            guard = RepetitionGuard()
            # Include a nonperiodic prefix and empty-decoding-equivalent tokens:
            # detection relies on IDs, never on decoded text fragments.
            for token in range(3000, 3173):
                self.assertFalse(guard.repeated(token))
            detected = False
            span = max(4, (guard.MIN_SPAN + period - 1) // period) * period
            for index in range(span + guard.INTERVAL):
                if guard.repeated(index % period):
                    detected = True
                    break
            self.assertTrue(detected, period)
            self.assertLessEqual(len(guard.tokens), guard.WINDOW)
        guard = RepetitionGuard()
        rng = random.Random(73)
        for token in [0] * 191 + [rng.randrange(32000) for _ in range(20000)]:
            self.assertFalse(guard.repeated(token))
        self.assertEqual(len(guard.tokens), guard.WINDOW)

    def test_minimal_fragment_length_is_an_explicit_error(self):
        with self.assertRaisesRegex(ValueError, "最大トークン数を増やして"):
            self.run_translation(request("👨‍👩‍👧‍👦"), force_length=True)
        self.assertFalse(any(e["event"] in {"delta", "done"} for e in self.events))

    def test_disabling_keeps_single_pass_and_length_status(self):
        output = self.run_translation(request("hello", auto_split=False), force_length=True)
        self.assertEqual(output, "DISCARDED")
        self.assertEqual(self.events[-1]["finish_reason"], "length")
        self.assertEqual(len(self.attempts), 1)
        self.assertFalse(any(e["event"] == "draft" for e in self.events))
        with self.assertRaisesRegex(ValueError, "32768"):
            self.run_translation(request("x" * 33000, auto_split=False))

    def test_retry_reduces_source_and_space_joining(self):
        for text in ["hello world", "日本語。テスト。", "  test\n\ncase  "]:
            parts = split_again(text)
            self.assertEqual("".join(parts), text)
            self.assertTrue(all(part.strip() and len(part) < len(text) for part in parts))
        self.assertEqual(output_separator("a", "b", "en"), " ")
        self.assertEqual(output_separator("。", "文", "ja"), "")
        self.assertEqual(output_separator("\n", "a", "en"), "")
        self.assertEqual(output_separator("a", ".", "en"), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
