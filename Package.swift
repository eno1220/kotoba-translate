// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KotobaTranslate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "KotobaTranslate", targets: ["KotobaTranslate"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/RusticPotatos/SwiftReadability", from: "0.1.8"),
        .package(url: "https://github.com/jaywcjlove/HTMLToMarkdown", from: "1.0.0")
    ],
    targets: [.executableTarget(name: "KotobaTranslate",
                               dependencies: [
                                   .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                                   .product(name: "SwiftReadability", package: "SwiftReadability"),
                                   .product(name: "HTMLToMarkdown", package: "HTMLToMarkdown")
                               ],
                               resources: [.copy("Resources")],
                               swiftSettings: [.swiftLanguageMode(.v5)])]
)
