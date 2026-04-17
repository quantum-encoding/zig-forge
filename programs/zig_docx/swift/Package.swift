// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZigDocx",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ZigDocx", type: .static, targets: ["ZigDocx"]),
    ],
    targets: [
        // C module wrapping the header — allows `import CZigDocx`
        .systemLibrary(
            name: "CZigDocx",
            path: "Sources/CZigDocx",
            pkgConfig: nil,
            providers: nil
        ),
        // Swift wrapper
        .target(
            name: "ZigDocx",
            dependencies: ["CZigDocx"],
            path: "Sources/ZigDocx"
        ),
    ]
)
