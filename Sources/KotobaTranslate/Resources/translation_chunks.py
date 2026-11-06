"""Lossless source partitioning; all limits are checked with the loaded tokenizer."""
import re
import unicodedata

CONTEXT_LIMIT = 32768


def safe_cut(text, limit):
    """Avoid cutting combining sequences, emoji modifiers, flags and ZWJ emoji."""
    cut = min(limit, len(text))
    while 0 < cut < len(text):
        current, previous = text[cut], text[cut - 1]
        if (unicodedata.category(current).startswith("M") or current == "\u200d"
                or previous == "\u200d" or "\U0001f3fb" <= current <= "\U0001f3ff"):
            cut -= 1
            continue
        if "\U0001f1e6" <= current <= "\U0001f1ff":
            start = cut
            while start and "\U0001f1e6" <= text[start - 1] <= "\U0001f1ff":
                start -= 1
            if (cut - start) % 2:
                cut -= 1
                continue
        break
    return cut


def natural_cut(text, limit):
    """Prefer paragraphs, lines, sentences, clauses, then words in the latter half.

    Fenced Markdown blocks stay intact when a nearby outside boundary is available.
    An oversized block/sentence still has a Unicode-safe fallback.
    """
    limit = safe_cut(text, limit)
    if not limit or limit == len(text):
        return limit
    sample = text[:limit]
    spans = []
    opened = None
    for match in re.finditer(r"(?m)^ {0,3}(`{3,}|~{3,})([^\n]*)(?:\n|$)", sample):
        marker = match[1]
        if opened is None:
            opened = (match.start(), marker[0], len(marker))
        elif marker[0] == opened[1] and len(marker) >= opened[2] and not match[2].strip():
            spans.append((opened[0], match.end()))
            opened = None
    if opened:
        spans.append((opened[0], len(sample) + 1))

    floor = max(1, limit // 2)
    patterns = (
        r"\n[ \t]*\n+",                         # Paragraphs / Markdown blocks.
        r"[。！？!?][\"'”’」』）)]*[ \t]*|(?<!\d)\.[\"'”’)]*\s+",
        r"\n",                                  # Lists, headings and table rows.
        r"[；;、，,：:][ \t]*",                  # Long sentences.
        r"[ \t]+",
    )
    for pattern in patterns:
        for match in reversed(list(re.finditer(pattern, sample))):
            cut = match.end()
            if cut < floor:
                break
            if not any(start < cut < end for start, end in spans) and safe_cut(text, cut) == cut:
                return cut
    return limit


def plan_chunks(request, tokenizer, build_prompt):
    # Validate the *whole* request before splitting (including reserved PFML tokens).
    build_prompt(request, tokenizer.bos_token or "")
    max_tokens = request["max_tokens"]
    # Allow 2x source-token expansion and retain another 20% of the output budget.
    # This is a heuristic, not a guarantee: length-truncated attempts are re-split.
    source_limit = max(1, int(max_tokens * 0.4))

    def fits(text):
        if not text.strip():
            return True
        if len(tokenizer.encode(text, add_special_tokens=False)) > source_limit:
            return False
        prompt = build_prompt(dict(request, text=text), tokenizer.bos_token or "")
        return len(tokenizer.encode(prompt, add_special_tokens=False)) + max_tokens <= CONTEXT_LIMIT

    text = request["text"]
    chunks = []
    offset = 0
    while offset < len(text):
        # Bound tokenizer work for very long documents; never repeatedly encode the
        # entire remaining document. Each chosen prefix is verified independently.
        window = text[offset:offset + max(64, source_limit * 8)]
        cut = len(window)
        if not fits(window):
            low, high, cut = 1, len(window) - 1, 0
            while low <= high:
                middle = (low + high) // 2
                if fits(window[:middle]):
                    cut = middle
                    low = middle + 1
                else:
                    high = middle - 1
            cut = natural_cut(window, cut)
        elif offset + cut < len(text):
            cut = natural_cut(window, cut - 1)
        # Token counts at a natural boundary can differ from those at the binary
        # search boundary. Check again; no monotonic token-count assumption is used
        # for the final context-window invariant.
        while cut and not fits(window[:cut]):
            cut = natural_cut(window, cut - 1)
        cut = safe_cut(text, offset + cut) - offset
        if not cut or not fits(window[:cut]):
            raise ValueError("最小の原文単位と生成枠が上限に収まりません。最大トークン数、Context、辞書を調整してください。")
        chunks.append(text[offset:offset + cut])
        offset += cut
    return chunks


def split_again(text):
    """A retry must strictly reduce both nonempty source pieces; it cannot loop."""
    core = text.strip()
    start = len(text) - len(text.lstrip())
    cut = natural_cut(core, len(core) // 2)
    if not cut or not core[:cut].strip() or not core[cut:].strip():
        raise ValueError("最小の原文単位でも生成上限に達しました。最大トークン数を増やしてください。")
    cut += start
    return [text[:cut], text[cut:]]


def output_separator(previous, current, target):
    # Keep original whitespace wherever present. When a no-space source boundary
    # becomes a spaced-language boundary, avoid joining translated words together.
    if (previous and current and not previous.isspace() and not current.isspace()
            and target not in {"ja", "zh-hans", "zh-hant", "th", "km", "my"}
            and current not in ".,;:!?。！？、，；：)]}”’」』"):
        return " "
    return ""
