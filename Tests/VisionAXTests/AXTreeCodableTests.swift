//
//  AXTreeCodableTests.swift
//  VisionAXTests
//
//  WHAT: The JSON contract — flat rects, string categories, recomputed subtreeCount.
//  OUT:  AXTreeCodable
//

import CoreGraphics
import Foundation
import Testing
@testable import VisionAX

@Suite struct AXTreeCodableTests {

    private func sampleWindow() -> AXWindowSnapshot {
        let button = AXNodeSnapshot(
            id: AXNodeID(raw: 3), role: "AXButton", subrole: "AXCloseButton",
            label: "Close", frame: CGRect(x: 80, y: 160, width: 160, height: 44),
            isEnabled: true, isFocused: true, category: .interactive)
        let pane = AXNodeSnapshot(
            id: AXNodeID(raw: 2), role: "AXGroup",
            frame: CGRect(x: 40, y: 120, width: 720, height: 440),
            category: .container, children: [button])
        let unplaced = AXNodeSnapshot(
            id: AXNodeID(raw: 4), role: "AXUnknown", frame: nil, category: .other)
        let root = AXNodeSnapshot(
            id: AXNodeID(raw: 1), role: "AXWindow",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            category: .window, children: [pane, unplaced])
        return AXWindowSnapshot(
            id: AXNodeID(raw: 1), title: "screenshot.png",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMain: true, isTruncated: false, root: root)
    }

    @Test func windowRoundTrips() throws {
        let window = sampleWindow()
        let json = try AXTreeJSON.encode(window)
        let decoded = try AXTreeJSON.decode(AXWindowSnapshot.self, from: json)
        #expect(decoded == window)
    }

    @Test func rectsEncodeFlat() throws {
        let json = try AXTreeJSON.encode(sampleWindow())
        #expect(json.contains("\"width\" : 800"))
        #expect(!json.contains("origin"), "CGRect's nested origin/size must not appear")
        #expect(!json.contains("\"size\""))
    }

    @Test func aNilFrameOmitsTheKey() throws {
        let node = AXNodeSnapshot(id: AXNodeID(raw: 9), role: "AXUnknown", category: .other)
        let json = try AXTreeJSON.encode(node)
        #expect(!json.contains("frame"))
        let decoded = try AXTreeJSON.decode(AXNodeSnapshot.self, from: json)
        #expect(decoded.frame == nil)
    }

    @Test func categoryEncodesAsItsName() throws {
        let json = try AXTreeJSON.encode(sampleWindow())
        #expect(json.contains("\"category\" : \"window\""))
        #expect(json.contains("\"category\" : \"interactive\""))
    }

    @Test func idEncodesAsABareInteger() throws {
        let json = try AXTreeJSON.encode(sampleWindow())
        #expect(json.contains("\"id\" : 1"))
    }

    @Test func subtreeCountIsRecomputedOnDecode() throws {
        // A hand-edited file claiming a wrong count must not poison the tree.
        let json = """
        {
          "id": 1, "title": "hand-written", "isMain": true, "isMinimized": false,
          "isTruncated": false,
          "frame": {"x": 0, "y": 0, "width": 100, "height": 100},
          "root": {
            "id": 1, "role": "AXWindow", "category": "window", "subtreeCount": 99,
            "isEnabled": true, "isFocused": false,
            "frame": {"x": 0, "y": 0, "width": 100, "height": 100},
            "children": [
              {"id": 2, "role": "VXRegion", "category": "other", "subtreeCount": 77,
               "isEnabled": true, "isFocused": false, "children": [],
               "frame": {"x": 10, "y": 10, "width": 20, "height": 20}}
            ]
          }
        }
        """
        let decoded = try AXTreeJSON.decode(AXWindowSnapshot.self, from: json)
        #expect(decoded.root?.subtreeCount == 2)
        #expect(decoded.root?.children.first?.subtreeCount == 1)
    }

    @Test func theShippedFixtureDecodes() throws {
        let url = try #require(Bundle.module.url(
            forResource: "sample-axtree", withExtension: "json", subdirectory: "Fixtures"))
        let window = try AXTreeJSON.decode(AXWindowSnapshot.self, from: Data(contentsOf: url))
        #expect(window.title == "sample-screenshot.png")
        #expect(window.root?.role == VisionAX.windowRole)
        let regions = SyntheticScreen.nodes(in: window).dropFirst()
        #expect(regions.allSatisfy { $0.role == VisionAX.regionRole })
        #expect(window.root?.subtreeCount == SyntheticScreen.nodes(in: window).count)
    }

    @Test func appSnapshotRoundTripsWithDuration() throws {
        let snapshot = AXAppSnapshot(
            pid: 501, bundleID: "nyc.rao.visionax.bench", appName: "VisionAX Bench",
            windows: [sampleWindow()], capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            walkDuration: .milliseconds(1250), nodeCount: 4)
        let json = try AXTreeJSON.encode(snapshot)
        #expect(json.contains("\"walkDuration\" : 1.25"))
        let decoded = try AXTreeJSON.decode(AXAppSnapshot.self, from: json)
        #expect(decoded == snapshot)
        #expect(decoded.walkDuration == .milliseconds(1250))
    }

    @Test func screenElementRoundTrips() throws {
        let element = AXScreenElement(
            ordinal: 1, id: AXNodeID(raw: 3), pid: 501, appName: "VisionAX Bench",
            windowID: AXNodeID(raw: 1), windowTitle: "screenshot.png",
            role: "AXButton", subrole: "AXCloseButton", category: .interactive,
            label: "Close", frame: CGRect(x: 80, y: 160, width: 160, height: 44),
            containerTrail: ["Content"])
        let json = try AXTreeJSON.encode(element)
        #expect(try AXTreeJSON.decode(AXScreenElement.self, from: json) == element)
    }

    @Test func encodedOutputEndsInANewline() throws {
        let json = try AXTreeJSON.encode(sampleWindow())
        #expect(json.hasSuffix("\n"))
        #expect(try !AXTreeJSON.encode(sampleWindow(), prettyPrinted: false).hasSuffix("\n"))
    }
}
