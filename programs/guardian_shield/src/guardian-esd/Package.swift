// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GuardianESD",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "guardian-esd", targets: ["GuardianESD"])
    ],
    targets: [
        .executableTarget(
            name: "GuardianESD",
            path: "Sources/GuardianESD",
            linkerSettings: [
                .linkedLibrary("EndpointSecurity"),
                .linkedLibrary("bsm")
            ]
        )
    ]
)
