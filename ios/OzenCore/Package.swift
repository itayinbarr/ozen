// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OzenCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OzenCore", targets: ["OzenCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "OzenCore",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ]
        ),
        .testTarget(
            name: "OzenCoreTests",
            dependencies: ["OzenCore"]
        ),
    ]
)
