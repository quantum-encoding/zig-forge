// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZigPdf",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ZigPdf", targets: ["ZigPdf"]),
    ],
    targets: [
        .systemLibrary(
            name: "CZigPdf",
            path: "Sources/CZigPdf",
            pkgConfig: nil,
            providers: nil
        ),
        .target(
            name: "ZigPdf",
            dependencies: ["CZigPdf"],
            path: "Sources/ZigPdf"
        ),
    ]
)
