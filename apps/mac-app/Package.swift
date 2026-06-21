// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Insta360Sync",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Insta360Sync",
            path: "Sources/Insta360Sync",
            resources: [
                .process("Resources/public"),
                .copy("Resources/ucd2"),
            ],
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
            ]
        ),
    ]
)
