// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TipPluginKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TipPluginKit", targets: ["TipPluginKit"])],
    targets: [
        .target(name: "TipPluginKit"),
        .testTarget(name: "TipPluginKitTests", dependencies: ["TipPluginKit"]),
    ]
)
