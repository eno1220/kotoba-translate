#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
saved_sdk="${SDKROOT:-$(xcrun --show-sdk-path)}"
mkdir -p .build/checks
swiftc -parse-as-library -swift-version 5 -sdk "$saved_sdk" -module-cache-path .build/ModuleCache \
    Sources/KotobaTranslate/{SavedTranslation,SavedTranslationStore}.swift \
    scripts/check-saved-translations.swift -o .build/checks/check-saved-translations
.build/checks/check-saved-translations
