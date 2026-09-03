//
//  HarvestSampleCodableTests.swift
//  VisionAXTests
//
//  WHAT: The dataset survives the round trip Python will make.
//  PIN:  The label field is a bare string on the wire; "none"/"ignore" must not be
//        confusable with a role, and a role must not decode as a sentinel.
//

import CoreGraphics
import Foundation
import Testing
@testable import VisionAX

@Suite struct HarvestSampleCodableTests {

    private func sample() -> HarvestSample {
        HarvestSample(
            id: "web-abc123",
            source: .web,
            origin: HarvestOrigin(url: "https://example.com/a", title: "Example", seed: 42),
            image: HarvestImageInfo(width: 2560, height: 1600, scale: 2.0),
            scheme: "dark",
            viewport: HarvestViewport(width: 1280, height: 800, zoom: 1.0, scrollY: 800),
            canny: .standard,
            engineVersion: VisionAX.version,
            elements: [
                GroundTruthElement(
                    index: 0, role: "AXButton", text: "Sign in",
                    rect: PixelRect(x: 10, y: 20, width: 120, height: 44),
                    interactive: true, depth: 3, parent: -1, tag: "button"),
                GroundTruthElement(
                    index: 1, role: "AXStaticText", text: "Hello",
                    rect: PixelRect(x: 14, y: 24, width: 112, height: 36),
                    depth: 4, parent: 0, matchable: false),
            ],
            regions: [
                RegionSample(
                    index: 0, parent: -1, depth: 1,
                    rect: PixelRect(x: 10, y: 20, width: 120, height: 44),
                    label: .role("AXButton"), matchIoU: 0.98, matchedElement: 0,
                    secondIoU: 0.41, secondElement: 1),
                RegionSample(
                    index: 1, parent: 0, depth: 2,
                    rect: PixelRect(x: 900, y: 900, width: 30, height: 30),
                    label: .none),
                RegionSample(
                    index: 2, parent: -1, depth: 1,
                    rect: PixelRect(x: 40, y: 40, width: 60, height: 60),
                    label: .ignore, matchIoU: 0.42, matchedElement: 0),
            ])
    }

    @Test func aSampleRoundTrips() throws {
        let original = sample()
        let json = try AXTreeJSON.encode(original)
        let decoded = try AXTreeJSON.decode(HarvestSample.self, from: json)
        #expect(decoded == original)
    }

    @Test func labelsEncodeAsBareStrings() throws {
        let json = try AXTreeJSON.encode(sample())
        #expect(json.contains("\"label\" : \"AXButton\""))
        #expect(json.contains("\"label\" : \"none\""))
        #expect(json.contains("\"label\" : \"ignore\""))
    }

    @Test func eachLabelFormDecodesBack() throws {
        #expect(try AXTreeJSON.decode(RegionMatchLabel.self, from: "\"AXLink\"") == .role("AXLink"))
        #expect(try AXTreeJSON.decode(RegionMatchLabel.self, from: "\"none\"") == .none)
        #expect(try AXTreeJSON.decode(RegionMatchLabel.self, from: "\"ignore\"") == .ignore)
    }

    @Test func rectsEncodeFlatAndAsIntegers() throws {
        let json = try AXTreeJSON.encode(PixelRect(x: 1, y: 2, width: 3, height: 4))
        #expect(json.contains("\"height\" : 4"))
        #expect(!json.contains("origin"))
    }

    @Test func theWriterRoundTripsThroughDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionax-dataset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try DatasetWriter(root: root)
        try writer.writeRoles(.standard)
        let original = sample()
        try writer.write(sample: original, image: SyntheticScreen.image())
        try writer.appendRun(DatasetManifest.Run(
            id: "run-1", source: .web, startedAt: Date(), count: 1, canny: .standard))

        #expect(try writer.sampleIDs() == ["web-abc123"])
        #expect(try writer.loadSample(id: "web-abc123") == original)
        #expect(try writer.loadManifest().runs.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("images/web-abc123.png").path))

        // roles.json carries Mary's category so Python cannot keep a stale copy.
        let rolesData = try Data(contentsOf: writer.rolesURL)
        let table = try AXTreeJSON.decode([RoleTableEntry].self, from: rolesData)
        #expect(table.count == RoleVocabulary.standard.classCount)
        #expect(table[0] == RoleTableEntry(index: 0, role: "none", category: "other"))
        #expect(table.first { $0.role == "AXButton" }?.category == "interactive")
        #expect(table.first { $0.role == "AXStaticText" }?.category == "text")
    }

    @Test func appendingARunTwiceReplacesIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionax-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DatasetWriter(root: root)
        let run = DatasetManifest.Run(
            id: "run-1", source: .app, startedAt: Date(), count: 1, canny: .standard)
        try writer.appendRun(run)
        var updated = run
        updated.count = 99
        try writer.appendRun(updated)

        let runs = try writer.loadManifest().runs
        #expect(runs.count == 1)
        #expect(runs[0].count == 99)
    }
}
