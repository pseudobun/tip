// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "tip",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "tip", targets: ["tip"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure logic (config, themes, layout solver, protocol, formatting): no AppKit, unit tested.
        .target(name: "TipCore"),
        // The app and its CLI: one binary.
        .executableTarget(
            name: "tip",
            dependencies: ["TipCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Sparkle.framework sits in tip.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(name: "TipCoreTests", dependencies: ["TipCore"]),
    ]
)
