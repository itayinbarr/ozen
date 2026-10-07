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
        // C wrapper over ORT's C++ API (the Objective-C bindings can't make bool tensors,
        // which the merged decoder's `use_cache_branch` input needs).
        .target(
            name: "COzenORT",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ]
        ),
        .target(
            name: "OzenCore",
            dependencies: ["COzenORT"]
        ),
        .testTarget(
            name: "OzenCoreTests",
            dependencies: ["OzenCore"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
