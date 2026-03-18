// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "loong-md",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "LoongMD",
            targets: ["LoongMD"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LoongMD",
            path: "Sources/LoongMD",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
