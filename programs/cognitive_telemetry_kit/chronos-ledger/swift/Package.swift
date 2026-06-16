// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChronosLedger",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "ChronosLedger", targets: ["ChronosLedger"]),
        .executable(name: "chronos-emit-demo", targets: ["chronos-emit-demo"]),
    ],
    targets: [
        .target(name: "ChronosLedger"),
        .executableTarget(name: "chronos-emit-demo", dependencies: ["ChronosLedger"]),
        .testTarget(name: "ChronosLedgerTests", dependencies: ["ChronosLedger"]),
    ]
)
