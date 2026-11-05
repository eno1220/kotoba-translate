# Kotoba Translate

## Scope and architecture
- Personal-use macOS app for Apple silicon, built with SwiftUI and AppKit (macOS 14+).
- Support only PLaMo 3 Translate MLX models. Users download models themselves; never add automatic model downloads or support for other models/formats.
- Use `uv` for Python dependencies. Keep inference in a private Python subprocess using `mlx-lm`, offline mode, and JSON Lines over stdin/stdout. Send diagnostics to stderr. The optional OpenAI-compatible HTTP API is hosted by the Swift app on loopback only; never expose the inference worker directly.
- Keep everything outside inference lightweight. Avoid unnecessary dependencies, abstractions, compatibility layers, and test infrastructure.

## Translation behavior
- Follow the official PLaMo 3 Translate MLX specification. Use PFML3 with `dataset=translation`, one BOS, and stop tokens `<|plamo:tag|>` and `<|plamo:bos|>`.
- Support the 53 documented languages, optional source-language detection, context, a global glossary, and Japanese-only `plain`/`polite` output styles.
- Expose max tokens and temperature; enforce input tokens + generation limit <= 32,768.
- Load only when translation starts. Reuse the model until configurable idle unloading; terminate the worker on cancellation, unloading, or app exit.
- Keep input/actions responsive. Stream output and show available progress, elapsed time, token counts, and generation speed.
- No history. Persist preferences, model registrations, and glossary only; do not save source text, translations, or context.

## UI requirements
- Follow Apple HIG: simple native controls, clear layout, minimal functional wording, light mode only, and the OS accent color. Green indicates model loading/loaded status.
- Keep model selection, status, and unloading inside translation options, not the title bar. Display user-defined model tags; select the configured default model at launch, falling back to the first registration.
- Preserve CJK IME composition: Enter submits, Shift+Enter inserts a newline, and Enter during composition confirms it.
- Provide copy/clear actions and an easily accessible options toggle (Option-Command-O).
- Default to raw text; use `swift-markdown-ui` for optional previews. Avoid reparsing unchanged Markdown.
- Configure source/output fonts independently: family, size, actual native font face, and text color. List each family's real faces (e.g. W3/W6), not fixed generic weights; load the exact PostScript name.
- Show character count and clearly labeled approximate source-token count without starting Python or loading a model. Debounce and compute off the main thread.

## Development
- Python setup: `uv sync --python 3.12`.
- Build: `zsh scripts/build-app.sh`. This generates the icon from `Assets/AppIcon.png`, packages resources, and signs `dist/Kotoba Translate.app` locally.
- This machine's 27.2 SDK lacks SwiftUI macros; use `zsh scripts/build-app.sh --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
- The app references the repository's `.venv` by absolute path; preserve it unless explicitly changing packaging.
- Rebuild after changes and verify with `codesign --verify --deep --strict "dist/Kotoba Translate.app"`. Use focused checks where useful; distinguish build verification from UI or real-model verification.
