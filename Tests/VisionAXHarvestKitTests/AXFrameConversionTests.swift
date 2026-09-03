//
//  AXFrameConversionTests.swift
//  VisionAXHarvestKitTests
//
//  WHAT: The point→pixel maths of the app lane, and the skew guard, without TCC.
//  PIN:  The live walk needs Accessibility and Screen Recording, but the ARITHMETIC
//        that turns a global AX frame into a pixel rect does not — and that arithmetic
//        is where a silent, total corruption would live. A wrong origin or a wrong
//        scale produces a perfectly well-formed sample whose boxes are nowhere near
//        its pixels, and nothing downstream could tell.
//

import CoreGraphics
import Foundation
import Testing
@testable import VisionAX
@testable import VisionAXHarvestKit
@testable import VisionAXWeb

@Suite struct AXFrameConversionTests {

    private func node(
        _ index: Int, _ role: String, _ frame: CGRect, parent: Int = -1, depth: Int = 0
    ) -> WalkedNode {
        WalkedNode(
            index: index, parent: parent, depth: depth, role: role,
            subrole: nil, label: nil, frame: frame, isEnabled: true)
    }

    private func result(_ nodes: [WalkedNode]) -> AXWalkResult {
        AXWalkResult(nodes: nodes, truncated: false, duration: .milliseconds(1))
    }

    @Test func aFrameBecomesWindowRelativePixels() {
        // A window at (100, 200) on screen; a button 40pt right and 10pt down of its
        // corner, captured at 2x.
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let button = CGRect(x: 140, y: 210, width: 120, height: 30)
        let bounds = PixelRect(x: 0, y: 0, width: 1600, height: 1200)

        let truth = AXWalker.groundTruth(
            result([node(0, "AXWindow", window), node(1, "AXButton", button, parent: 0, depth: 1)]),
            windowOrigin: window.origin, scale: 2.0, imageBounds: bounds)

        #expect(truth[0].rect == PixelRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(truth[1].rect == PixelRect(x: 80, y: 20, width: 240, height: 60))
        #expect(truth[1].matchable)
    }

    @Test func aOneTimesCaptureIsNotScaled() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let truth = AXWalker.groundTruth(
            result([node(0, "AXWindow", window),
                    node(1, "AXButton", CGRect(x: 10, y: 20, width: 100, height: 40),
                         parent: 0, depth: 1)]),
            windowOrigin: window.origin, scale: 1.0,
            imageBounds: PixelRect(x: 0, y: 0, width: 800, height: 600))
        #expect(truth[1].rect == PixelRect(x: 10, y: 20, width: 100, height: 40))
    }

    @Test func aRowScrolledOutOfItsScrollAreaIsNotVisible() {
        // The row's own frame is honest — AX reports where it would be — but half the
        // screen away from the scroll area that clips it.
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let scroller = CGRect(x: 0, y: 0, width: 400, height: 200)
        let offscreenRow = CGRect(x: 0, y: 400, width: 400, height: 30)
        let visibleRow = CGRect(x: 0, y: 20, width: 400, height: 30)

        let truth = AXWalker.groundTruth(
            result([
                node(0, "AXWindow", window),
                node(1, "AXScrollArea", scroller, parent: 0, depth: 1),
                node(2, "AXRow", offscreenRow, parent: 1, depth: 2),
                node(3, "AXRow", visibleRow, parent: 1, depth: 2),
            ]),
            windowOrigin: window.origin, scale: 1.0,
            imageBounds: PixelRect(x: 0, y: 0, width: 800, height: 600))

        #expect(truth[2].visible == false, "a row below its scroll area should not count")
        #expect(truth[2].matchable == false)
        #expect(truth[3].visible == true)
    }

    @Test func onlyVocabularyRolesAreMatchable() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        let truth = AXWalker.groundTruth(
            result([
                node(0, "AXWindow", window),
                node(1, "AXButton", CGRect(x: 0, y: 0, width: 80, height: 30), parent: 0, depth: 1),
                node(2, "AXUnknown", CGRect(x: 0, y: 40, width: 80, height: 30), parent: 0, depth: 1),
            ]),
            windowOrigin: window.origin, scale: 1.0,
            imageBounds: PixelRect(x: 0, y: 0, width: 400, height: 300))

        #expect(truth[1].matchable)
        #expect(truth[2].matchable == false, "AXUnknown is outside the vocabulary")
        // The window itself is not something to detect either.
        #expect(truth[0].matchable == false)
    }

    @Test func aSliverOfAnElementIsNotWorthFinding() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        let truth = AXWalker.groundTruth(
            result([
                node(0, "AXWindow", window),
                node(1, "AXButton", CGRect(x: 0, y: 0, width: 80, height: 2), parent: 0, depth: 1),
            ]),
            windowOrigin: window.origin, scale: 1.0,
            imageBounds: PixelRect(x: 0, y: 0, width: 400, height: 300))
        #expect(truth[1].matchable == false, "2pt tall is under the matchable floor")
    }

    @Test func chromiumIsRecognisedAndSafariIsNot() {
        #expect(WebContentKind.classify(bundleID: "com.google.Chrome") == .chromium)
        #expect(WebContentKind.classify(bundleID: "com.brave.Browser") == .chromium)
        #expect(WebContentKind.classify(bundleID: "company.thebrowser.Browser") == .chromium)
        #expect(WebContentKind.classify(bundleID: "com.apple.Safari") == .webKit)
        #expect(WebContentKind.classify(bundleID: "com.apple.TextEdit") == .none)

        // Only the engines that build no tree until asked need waking.
        #expect(WebContentKind.chromium.needsManualAccessibility)
        #expect(WebContentKind.electron.needsManualAccessibility)
        #expect(!WebContentKind.webKit.needsManualAccessibility)
        #expect(!WebContentKind.none.needsManualAccessibility)
    }

    @Test func identicalCapturesShowNoSkew() throws {
        let image = SyntheticScreen.simpleImage(width: 200, height: 120)
        #expect(WindowCapture.difference(image, image) == 0)
    }

    @Test func aChangedCaptureShowsSkew() throws {
        let a = SyntheticScreen.simpleImage(width: 200, height: 120)
        let b = SyntheticScreen.simpleImage(width: 200, height: 120, shifted: true)
        #expect(WindowCapture.difference(a, b) > 0.01, "a moved block should register")
    }
}

/// Two small images that differ only where a block sits — enough to exercise the
/// skew guard without a screen.
enum SyntheticScreen {
    static func simpleImage(width: Int, height: Int, shifted: Bool = false) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: shifted ? 90 : 10, y: 20, width: 80, height: 60))
        return context.makeImage()!
    }
}
