// swift-tools-version: 6.0
// WHAT: VisionAX's tools — the web crawler, the harvester that builds the training set, and
//       the bench that tunes the detector and shows what the classifier said.
// IN:   VisionAXCore (this repository's root package) and Frigate's FrigateVisionAX
//       product — the runtime these tools drive.
// PIN:  A SECOND PACKAGE, NOT TARGETS IN THE ROOT ONE. The harvester and the bench run the
//       engine, the engine lives in Frigate, and Frigate depends on VisionAXCore — declaring
//       these beside VisionAXCore would make the two packages depend on each other.
//       The web lane needs only VisionAXCore: it renders a page and asks its DOM what is
//       there, and neither half of that is the runtime.

import PackageDescription

let package = Package(
    name: "VisionAXTools",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "VisionAXBench", targets: ["VisionAXBench"]),
        .executable(name: "VisionAXHarvest", targets: ["VisionAXHarvest"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(path: "../../Frigate"),
    ],
    targets: [
        // MARK: - VisionAXWeb — render a page, ask the DOM what is on it.
        // PIN: SPLIT OUT SO THE BENCH CAN HAVE IT WITHOUT THE REST. Everything here is
        //      permission-free — WebKit and nothing else — while its sibling walks live
        //      accessibility trees and captures the screen.
        .target(
            name: "VisionAXWeb",
            dependencies: [
                .product(name: "VisionAXCore", package: "VisionAX")
            ],
            path: "Sources/VisionAXWeb",
            resources: [
                .copy("Resources/harvest.js"),
                .copy("Resources/Seeds"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("WebKit")
            ]
        ),

        // MARK: - VisionAXHarvestKit — the lane that needs permission.
        // PIN: A LIBRARY, not part of the app target, so the parts that CAN be tested
        //      without a TCC grant are.
        .target(
            name: "VisionAXHarvestKit",
            dependencies: [
                "VisionAXWeb",
                .product(name: "FrigateVisionAX", package: "Frigate"),
            ],
            path: "Sources/VisionAXHarvestKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "VisionAXHarvestKitTests",
            dependencies: [
                "VisionAXHarvestKit",
                "VisionAXWeb",
                .product(name: "FrigateVisionAX", package: "Frigate"),
            ],
            path: "Tests/VisionAXHarvestKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - VisionAXHarvest — the app shell around the kit.
        // PIN: Its own bundle id (nyc.rao.visionax.harvest), so granting the harvester
        //      Accessibility never grants it to the bench or to Mary.
        .executableTarget(
            name: "VisionAXHarvest",
            dependencies: [
                "VisionAXHarvestKit",
                "VisionAXWeb",
                .product(name: "FrigateVisionAX", package: "Frigate"),
            ],
            path: "Sources/VisionAXHarvestApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/HarvestInfo.plist",
                ])
            ]
        ),

        // MARK: - VisionAXBench — open an image, see the tree, the edges, the JSON.
        // PIN: Info.plist linked into the Mach-O so the bare .build binary is a real app
        //      with a bundle id — the same launch recipe as Mary's Sand.
        .executableTarget(
            name: "VisionAXBench",
            dependencies: [
                "VisionAXWeb",
                .product(name: "FrigateVisionAX", package: "Frigate"),
            ],
            path: "Sources/VisionAXBenchApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/BenchInfo.plist",
                ])
            ]
        ),
    ]
)
