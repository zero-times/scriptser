// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scriptser",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Scriptser", targets: ["Scriptser"])
    ],
    targets: [
        .executableTarget(
            name: "Scriptser",
            path: "Sources"
        )
    ]
)
