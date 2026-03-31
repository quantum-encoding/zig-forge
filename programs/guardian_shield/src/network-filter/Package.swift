// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GuardianNetFilter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "guardian-netfilter", targets: ["NetworkFilter"])
    ],
    targets: [
        .executableTarget(
            name: "NetworkFilter",
            path: "Sources/NetworkFilter",
            linkerSettings: [
                .linkedFramework("NetworkExtension"),
                .linkedLibrary("EndpointSecurity"),
                .linkedLibrary("bsm")
            ]
        )
    ]
)
