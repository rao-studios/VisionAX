//
//  PermissionsGate.swift
//  VisionAXHarvest
//
//  WHAT: Whether this process may read the AX tree and capture the screen.
//  IN:   HarvestModel, before an app harvest
//  OUT:  the two TCC prompts, and a plain statement of what is missing
//  PIN:  ASKED SEPARATELY, because they fail differently and are granted in different
//        panes. Without Accessibility the AX walk returns an empty tree — no error, no
//        prompt, just nothing to match against. Without Screen Recording the capture
//        returns a desktop-picture-only image that LOOKS like a screenshot. Both
//        failures are silent, so the gate is checked before a run rather than
//        diagnosed after one. The web lane needs neither, which is why it is the
//        default lane.
//

import ApplicationServices
import CoreGraphics
import Foundation

struct PermissionsGate {
    var accessibility: Bool
    var screenRecording: Bool

    var isReady: Bool { accessibility && screenRecording }

    static func current() -> PermissionsGate {
        PermissionsGate(
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess())
    }

    /// Prompts for whatever is missing. Both prompts are one-shot per app identity:
    /// macOS shows them once and thereafter the user must visit System Settings.
    static func request() -> PermissionsGate {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        return current()
    }

    var missingDescription: String {
        var missing: [String] = []
        if !accessibility { missing.append("Accessibility") }
        if !screenRecording { missing.append("Screen Recording") }
        guard !missing.isEmpty else { return "" }
        return missing.joined(separator: " and ")
            + " — grant in System Settings ▸ Privacy & Security, then relaunch."
    }
}
