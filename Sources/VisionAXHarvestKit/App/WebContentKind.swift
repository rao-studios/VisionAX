//
//  WebContentKind.swift
//  VisionAXHarvestKit
//
//  WHAT: Which browser engine an app is, and how to make it answer.
//  IN:   AppHarvester (a bundle id and a bundle path)
//  OUT:  the AXManualAccessibility wake
//  PIN:  CHROMIUM AND ELECTRON BUILD NO ACCESSIBILITY TREE UNTIL SOMEBODY ASKS. Until
//        the AXManualAccessibility flag is set, walking Chrome returns a window with
//        almost nothing in it — which looks exactly like a page that has not loaded, so
//        the failure is easy to misread as a timing problem and "fix" with a sleep.
//        Electron and CEF are detected by what is on disk rather than by an allowlist,
//        because the set of Electron apps is unbounded. Twin of Mary's WebContentHost.
//

import AppKit
import ApplicationServices
import Foundation

public enum WebContentKind: String, Sendable, Equatable {
    case webKit
    case chromium
    case electron
    case none

    static let webKitPrefixes = ["com.apple.Safari"]
    static let chromiumPrefixes = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
    ]

    public static func classify(bundleID: String?, bundleURL: URL? = nil) -> WebContentKind {
        if let bundleID {
            if webKitPrefixes.contains(where: bundleID.hasPrefix) { return .webKit }
            if chromiumPrefixes.contains(where: bundleID.hasPrefix) { return .chromium }
        }
        guard let bundleURL else { return .none }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let manager = FileManager.default
        if manager.fileExists(atPath:
            frameworks.appendingPathComponent("Electron Framework.framework").path) {
            return .electron
        }
        if manager.fileExists(atPath:
            frameworks.appendingPathComponent("Chromium Embedded Framework.framework").path) {
            return .chromium
        }
        return .none
    }

    /// Whether this engine needs waking before it will describe its content.
    public var needsManualAccessibility: Bool {
        self == .chromium || self == .electron
    }
}

enum WebContentWake {
    /// Sets the flag and waits for a web area to appear. Returns whether one did.
    ///
    /// Polling rather than trusting the setter: the flag is a request, and the renderer
    /// builds its tree asynchronously afterwards.
    static func wake(app: AXUIElement, timeout: Duration = .seconds(3)) async -> Bool {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if findWebArea(in: app, depth: 0, maxDepth: 12) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return findWebArea(in: app, depth: 0, maxDepth: 12)
    }

    private static func findWebArea(in element: AXUIElement, depth: Int, maxDepth: Int) -> Bool {
        guard depth <= maxDepth else { return false }
        let role = AXAttributes.role(element)
        if role == "AXWebArea" { return true }
        for child in AXAttributes.children(element, role: role) {
            if findWebArea(in: child, depth: depth + 1, maxDepth: maxDepth) { return true }
        }
        return false
    }
}
