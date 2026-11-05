// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KotobaTranslate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "KotobaTranslate", targets: ["KotobaTranslate"])],
    dependencies: [.package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")],
    targets: [.executableTarget(name: "KotobaTranslate",
                               dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")],
                               resources: [.copy("Resources")],
                               swiftSettings: [.swiftLanguageMode(.v5)])]
)
