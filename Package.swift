// swift-tools-version:5.9
// このパッケージは Core（プロトコル・画像変換などUI/NFC非依存のロジック）だけを
// `swift test` で検証するためのものです。アプリ本体は EPaperCase.xcodeproj を開いてください。
import PackageDescription

let package = Package(
    name: "EPaperCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "EPaperCore", targets: ["EPaperCore"])
    ],
    targets: [
        .target(name: "EPaperCore", path: "EPaperCase/Core"),
        .testTarget(name: "EPaperCoreTests", dependencies: ["EPaperCore"], path: "Tests/EPaperCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
