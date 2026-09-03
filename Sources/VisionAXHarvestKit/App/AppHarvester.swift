//
//  AppHarvester.swift
//  VisionAXHarvestKit
//
//  WHAT: A running app's AX tree paired with a capture of the same moment.
//  IN:   a bundle id
//  OUT:  AppCapture (image + ground truth) for HarvestSession
//  PIN:  CAPTURE, WALK, CAPTURE AGAIN — and throw the sample away if the two captures
//        disagree. An AX walk of a busy window takes hundreds of milliseconds, and
//        anything that animates, loads or blinks in that window moves the boxes out
//        from under the pixels. Nothing downstream could ever detect that: the sample
//        would look perfectly well formed and simply teach the model wrong geometry.
//        Discarding a few samples is much cheaper than finding this later.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VisionAX

public enum AppHarvestError: Error, CustomStringConvertible {
    case notRunning(String)
    case noWindow(String)
    case screenChangedDuringWalk(Double)
    case emptyTree(String)

    public var description: String {
        switch self {
        case .notRunning(let bundleID): return "\(bundleID) is not running"
        case .noWindow(let bundleID): return "\(bundleID) has no standard window on screen"
        case .screenChangedDuringWalk(let amount):
            return "the window changed by \(Int(amount * 100))% while it was being walked"
        case .emptyTree(let bundleID):
            return "\(bundleID) exposed no accessibility tree — is Accessibility granted?"
        }
    }
}

public struct AppCapture: Sendable {
    public var image: CGImage
    public var elements: [GroundTruthElement]
    public var windowTitle: String
    public var scale: Double
    public var walkMilliseconds: Int
    public var truncated: Bool
}

public final class AppHarvester {
    public let bundleID: String
    private let pid: pid_t
    private let application: AXUIElement
    private let engineKind: WebContentKind
    private var woken = false

    /// How much of the window may change during the walk before the pair is untrusted.
    public var skewTolerance = 0.005

    public init(bundleID: String) throws {
        guard let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).first else {
            throw AppHarvestError.notRunning(bundleID)
        }
        self.bundleID = bundleID
        self.pid = running.processIdentifier
        self.application = AXUIElementCreateApplication(pid)
        self.engineKind = WebContentKind.classify(
            bundleID: bundleID, bundleURL: running.bundleURL)
        // App-global, and the default is effectively no timeout at all.
        AXAttributes.setMessagingTimeout(application, seconds: 0.25)
    }

    public func capture() async throws -> AppCapture {
        if engineKind.needsManualAccessibility, !woken {
            woken = await WebContentWake.wake(app: application)
        }

        guard let window = frontStandardWindow() else {
            throw AppHarvestError.noWindow(bundleID)
        }
        let axFrame = AXAttributes.frame(window)

        let before = try await WindowCapture.capture(pid: pid, matching: axFrame)
        let walk = AXWalker.walk(window: window)
        let after = try await WindowCapture.capture(pid: pid, matching: axFrame)

        guard !walk.nodes.isEmpty else { throw AppHarvestError.emptyTree(bundleID) }

        let drift = WindowCapture.difference(before.image, after.image)
        guard drift <= skewTolerance, before.frame == after.frame else {
            throw AppHarvestError.screenChangedDuringWalk(drift)
        }

        let bounds = PixelRect(x: 0, y: 0, width: after.image.width, height: after.image.height)
        let elements = AXWalker.groundTruth(
            walk,
            windowOrigin: after.frame.origin,
            scale: after.scale,
            imageBounds: bounds)

        return AppCapture(
            image: after.image,
            elements: elements,
            windowTitle: after.title.isEmpty ? bundleID : after.title,
            scale: after.scale,
            walkMilliseconds: Int(walk.duration.seconds * 1000),
            truncated: walk.truncated)
    }

    /// The frontmost standard window — not a sheet, not a popover, not minimized.
    private func frontStandardWindow() -> AXUIElement? {
        let windows = AXAttributes.elements(application, kAXWindowsAttribute as String)
        for window in windows {
            let subrole = AXAttributes.subrole(window)
            guard subrole == nil || subrole == (kAXStandardWindowSubrole as String) else { continue }
            if AXAttributes.bool(window, kAXMinimizedAttribute as String) == true { continue }
            return window
        }
        return windows.first
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
