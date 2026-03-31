// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GuardianShieldGUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GuardianShieldGUI", targets: ["GuardianShieldGUI"])
    ],
    targets: [
        .executableTarget(
            name: "GuardianShieldGUI",
            path: "Sources"
        )
    ]
)
