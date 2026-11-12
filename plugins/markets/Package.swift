// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "markets",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../sdk/swift")],
    targets: [
        .executableTarget(name: "markets", dependencies: [.product(name: "TipPluginKit", package: "swift")],
                          path: "Sources/Markets", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
