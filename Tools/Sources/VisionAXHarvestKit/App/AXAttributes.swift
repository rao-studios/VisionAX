//
//  AXAttributes.swift
//  VisionAXHarvestKit
//
//  WHAT: The handful of accessibility reads the walker needs, wrapped in Swift.
//  IN:   AXWalker, AppHarvester
//  OUT:  AXUIElement attribute values
//  PIN:  A MESSAGING TIMEOUT IS SET ONCE, ON THE APPLICATION ELEMENT, because it is an
//        app-global setting and because the default is effectively forever: one hung
//        renderer would stall a whole harvest with no error and no output. Frames come
//        back in GLOBAL TOP-LEFT POINTS, the same space ScreenCaptureKit reports window
//        frames in, so no flip happens anywhere in this package.
//

import ApplicationServices
import CoreGraphics
import Foundation

enum AXAttributes {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? "AXUnknown"
    }

    static func subrole(_ element: AXUIElement) -> String? {
        string(element, kAXSubroleAttribute as String)
    }

    /// Title, then description, then value — the ladder AX itself suggests, stopping at
    /// the first that says anything.
    static func label(_ element: AXUIElement, cap: Int) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = string(element, attribute as String), !text.isEmpty {
                return String(text.prefix(cap))
            }
        }
        if let text = value(element, kAXValueAttribute as String) as? String, !text.isEmpty {
            return String(text.prefix(cap))
        }
        return nil
    }

    /// Global, top-left-origin points. Nil when the element declines to place itself —
    /// walked, but not placeable, which is different from being at the origin.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute as String),
              let sizeValue = value(element, kAXSizeAttribute as String)
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Children, preferring the VISIBLE set where a role offers one. A 10,000-row table
    /// answers kAXChildren with all ten thousand, and the walk budget would be spent
    /// entirely inside it on rows that are not on screen.
    static func children(_ element: AXUIElement, role: String) -> [AXUIElement] {
        let virtualized = ["AXTable", "AXOutline", "AXList", "AXBrowser"]
        if virtualized.contains(role) {
            let rows = elements(element, kAXVisibleRowsAttribute as String)
            if !rows.isEmpty { return rows }
            let visible = elements(element, kAXVisibleChildrenAttribute as String)
            if !visible.isEmpty { return visible }
        }
        return elements(element, kAXChildrenAttribute as String)
    }

    static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
}
