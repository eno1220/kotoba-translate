"""Bounded token-cycle detection, independent of decoding and output length."""
from collections import deque


class RepetitionGuard:
    # Require both substantial output and at least four identical cycles. Checks
    # are deliberately sparse; ordinary short repetitions should pass untouched.
    INTERVAL = 32
    MIN_SPAN = 192
    MAX_PERIOD = 256
    WINDOW = MAX_PERIOD * 4

    def __init__(self):
        self.tokens = deque(maxlen=self.WINDOW)
        self.count = 0

    def repeated(self, token):
        self.tokens.append(token)
        self.count += 1
        if self.count % self.INTERVAL or len(self.tokens) < self.MIN_SPAN:
            return False
        tokens = list(self.tokens)
        for period in range(1, min(self.MAX_PERIOD, len(tokens) // 4) + 1):
            if tokens[-1] != tokens[-1 - period]:
                continue
            cycles = max(4, (self.MIN_SPAN + period - 1) // period)
            span = cycles * period
            if span <= len(tokens) and tokens[-span:-period] == tokens[-span + period:]:
                return True
        return False
