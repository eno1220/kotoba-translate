#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

article_sdk="${SDKROOT:-$(xcrun --show-sdk-path)}"
swift build -c release --sdk "$article_sdk"
article_bin_dir=$(swift build -c release --show-bin-path --sdk "$article_sdk")
swiftc -parse-as-library -sdk "$article_sdk" -I "$article_bin_dir" \
    Sources/KotobaTranslate/ArticleFetcher.swift scripts/check-article.swift \
    "$article_bin_dir/SwiftReadability.o" "$article_bin_dir/SwiftSoup.o" \
    "$article_bin_dir/HTMLToMarkdown.o" -o "$article_bin_dir/check-article"
"$article_bin_dir/check-article" "$@"
