#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
pdf_sdk="${SDKROOT:-$(xcrun --show-sdk-path)}"
mkdir -p .build/pdf-check
swiftc -parse-as-library -sdk "$pdf_sdk" -module-cache-path .build/ModuleCache \
    Sources/KotobaTranslate/PDFImporter.swift scripts/check-pdf.swift \
    -o .build/pdf-check/check-pdf
.build/pdf-check/check-pdf
