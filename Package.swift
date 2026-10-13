// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scriptser",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Scriptser", targets: ["Scriptser"])
    ],
    targets: [
        .executableTarget(
            name: "Scriptser",
            path: "Sources/Scriptser",
            resources: [.process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj"),
                        .copy("Resources/Skills"), .copy("Resources/AppIcon.icns")]
        ),
        .testTarget(name: "ScriptserTests", dependencies: ["Scriptser"])
    ]
)
