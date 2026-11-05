#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
server_sdk="${SDKROOT:-$(xcrun --show-sdk-path)}"
server_bin=$(swift build -c release --show-bin-path --sdk "$server_sdk")
# Run build-app.sh first. Link the existing article dependencies and point the check at the package resource bundle.
swiftc -parse-as-library -swift-version 5 -sdk "$server_sdk" -module-cache-path .build/ModuleCache -I "$server_bin" \
    Sources/KotobaTranslate/{Translator,TranslationRequest,LocalAPIServer,Preferences,FontCatalog,InputStatistics,InputLanguage,PDFImporter,ArticleFetcher}.swift \
    scripts/check-server.swift "$server_bin"/{SwiftReadability,SwiftSoup,HTMLToMarkdown}.o -o "$server_bin/check-server"
KOTOBA_CHECK_RESOURCE_BUNDLE="$server_bin/KotobaTranslate_KotobaTranslate.bundle" "$server_bin/check-server"
