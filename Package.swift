// swift-tools-version: 6.0
// WHAT: VisionAX — the AX/A11Y interoperability scaffolding (VisionAXCore), and beside it
//       the training pipeline (Training/) and the tools that feed and tune it (Tools/).
// OUT:  Frigate's `FrigateVisionAX` module — the vision runtime: the C++ engine, the
//       classifier, the page map — depends on VisionAXCore and re-exports it. Mary reaches
//       both through Frigate's product of the same name.
// PIN:  NO DEPENDENCIES, AND NO RUNTIME. VisionAXCore is the shape of an accessibility tree
//       and of a training sample — value types, their JSON, the role vocabulary — so a
//       trainer, a harvester and a consumer agree on it without any of them linking OpenCV,
//       ONNX Runtime or MLX.
//       THE TOOLS ARE A SECOND PACKAGE (Tools/Package.swift), because the harvester and the
//       bench need the runtime and the runtime needs this package: one package would be a
//       package-level cycle.
//       Language mode v5 on every target (matches Mary and Frigate's vision module).

import PackageDescription

let package = Package(
    name: "VisionAX",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "VisionAXCore", targets: ["VisionAXCore"]),
    ],
    targets: [
        // MARK: - VisionAXCore — the AX tree model, the dataset schema, the role vocabulary.
        .target(
            name: "VisionAXCore",
            path: "Sources/VisionAXCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VisionAXCoreTests",
            dependencies: ["VisionAXCore"],
            path: "Tests/VisionAXCoreTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
