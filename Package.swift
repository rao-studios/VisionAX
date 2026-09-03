// swift-tools-version: 6.0
// WHAT: VisionAX — OpenCV C engine (CVisionAX) → Swift wrapper (VisionAX) → bench app.
// OUT:  Mary consumes the `VisionAX` library product as a path dependency.
// PIN:  OpenCV and ONNX Runtime both arrive as prebuilt STATIC xcframeworks, never
//       Homebrew — the package builds on a clean machine with nothing but Xcode.
//       Language mode v5 on every target (matches Mary; C-imported types are
//       non-Sendable). CVisionAX's public header is pure C; C++ stays inside.

import PackageDescription

let package = Package(
    name: "VisionAX",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "VisionAX", targets: ["VisionAX"]),
        .executable(name: "VisionAXBench", targets: ["VisionAXBench"]),
        .executable(name: "VisionAXHarvest", targets: ["VisionAXHarvest"]),
    ],
    dependencies: [
        // Static opencv2.xcframework built from the upstream 4.13.0 tag by
        // platforms/apple/build_xcframework.py (macOS x86_64 + arm64).
        .package(url: "https://github.com/yeatse/opencv-spm.git", exact: "4.13.0"),
    ],
    targets: [
        // MARK: - ONNX Runtime — the inference runtime the classifier runs on.
        // PIN: OUR OWN binaryTarget, not Microsoft's SwiftPM package, whose only library
        //      product drags an Objective-C bindings target in behind it. This is the
        //      same archive that package points at, so the checksum is theirs too.
        //      The zip nests onnxruntime.xcframework one level down; SwiftPM finds it
        //      recursively and keeps only the xcframework, discarding the top-level
        //      Headers/ — so C++ includes must go through the framework
        //      (<onnxruntime/onnxruntime_c_api.h>), the way OpenCV's do.
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
            checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
        ),

        // MARK: - CVisionAX — the engine. C header out, C++ + OpenCV + ORT in.
        .target(
            name: "CVisionAX",
            dependencies: [
                .product(name: "OpenCV", package: "opencv-spm"),
                "onnxruntime",
            ],
            path: "Sources/CVisionAX",
            cxxSettings: [
                .define("VISIONAX_VERSION", to: "\"0.3.0\""),
            ],
            linkerSettings: [
                // The static ORT archive carries its CoreML execution provider's
                // Objective-C objects whether or not we ever append that provider, so
                // these two frameworks are needed to resolve them at link time.
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
            ]
        ),

        // MARK: - VisionAX — the Swift face: AXTree models + engine facade.
        .target(
            name: "VisionAX",
            dependencies: ["CVisionAX"],
            path: "Sources/VisionAX",
            resources: [
                // The trained classifier (git-lfs). Present or not, the directory ships
                // so Bundle.module exists and RegionClassifier.bundled() can look.
                .copy("Resources/Models"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Text recognition is Apple's, on the ANE, with nothing to download.
                .linkedFramework("Vision"),
            ]
        ),
        .testTarget(
            name: "VisionAXTests",
            dependencies: ["VisionAX"],
            path: "Tests/VisionAXTests",
            resources: [
                // Synthetic screens AND real captures — see MediaFixtureTests.
                .copy("Fixtures")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - VisionAXWeb — render a page, ask the DOM what is on it.
        // PIN: SPLIT OUT SO THE BENCH CAN HAVE IT WITHOUT THE REST. Everything here is
        //      permission-free — WebKit and nothing else — while its sibling walks live
        //      accessibility trees and captures the screen. The bench opens a URL by
        //      reusing this; making it depend on the whole harvest kit instead would
        //      have it linking ScreenCaptureKit and ApplicationServices to draw a
        //      screenshot, which is the sort of edge nobody can explain a year later.
        .target(
            name: "VisionAXWeb",
            dependencies: ["VisionAX"],
            path: "Sources/VisionAXWeb",
            resources: [
                .copy("Resources/harvest.js"),
                .copy("Resources/Seeds"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("WebKit"),
            ]
        ),

        // MARK: - VisionAXHarvestKit — the lane that needs permission.
        // PIN: A LIBRARY, not part of the app target, so the parts that CAN be tested
        //      without a TCC grant are. Only the live-app lane needs Accessibility and
        //      Screen Recording, and it is deliberately the thinnest part.
        .target(
            name: "VisionAXHarvestKit",
            dependencies: ["VisionAX", "VisionAXWeb"],
            path: "Sources/VisionAXHarvestKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "VisionAXHarvestKitTests",
            dependencies: ["VisionAXHarvestKit", "VisionAXWeb", "VisionAX"],
            path: "Tests/VisionAXHarvestKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - VisionAXHarvest — the app shell around the kit.
        // PIN: Its own bundle id (nyc.rao.visionax.harvest), so granting the harvester
        //      Accessibility never grants it to the bench or to Mary — same reason
        //      Mary's Sand carries an identity separate from Mary's.
        .executableTarget(
            name: "VisionAXHarvest",
            dependencies: ["VisionAXHarvestKit", "VisionAXWeb", "VisionAX"],
            path: "Sources/VisionAXHarvestApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/HarvestInfo.plist",
                ]),
            ]
        ),

        // MARK: - VisionAXBench — open an image, see the tree, the edges, the JSON.
        // PIN: Same launch recipe as Mary's Sand: Info.plist linked into the
        //      Mach-O so the bare .build binary is a real app with a bundle id.
        .executableTarget(
            name: "VisionAXBench",
            dependencies: ["VisionAX", "VisionAXWeb"],
            path: "Sources/VisionAXBenchApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/BenchInfo.plist",
                ]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
