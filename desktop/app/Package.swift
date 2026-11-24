// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OPLNetFleet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OPLNetFleet", targets: ["OPLNetFleet"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "OPLNetFleet",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: ".",
            exclude: [
                "Info.plist",
                ".gitignore",
            ],
            sources: [
                "AppUpdater.swift",
                "main.swift",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        )
    ]
)
