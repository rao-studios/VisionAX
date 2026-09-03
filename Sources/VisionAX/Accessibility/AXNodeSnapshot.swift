//
//  AXNodeSnapshot.swift
//  VisionAX
//
//  WHAT: Plain-Sendable AX tree. A field-for-field twin of Mary's
//        MaryComputerUse/Accessibility/AXNodeSnapshot.swift.
//  OUT:  RegionTreeBridge, AXTreeCodable, VisionAXBench
//  PIN:  Kept identical to Mary's so a VisionAX tree drops into Mary unchanged. The one
//        delta: AXNodeID has no `init(hashing: AXUIElement)` — no live AX here.
//

import CoreGraphics
import Foundation

/// A diffing HINT, not a proof of identity. In Mary it wraps `CFHash` of the live AX
/// node; here it is the region's pre-order ordinal.
public struct AXNodeID: Hashable, Sendable {
    public var raw: UInt

    public init(raw: UInt) {
        self.raw = raw
    }
}

/// One node's worth of accessibility state, frozen at capture time.
public struct AXNodeSnapshot: Sendable, Equatable, Identifiable {
    public var id: AXNodeID
    public var role: String
    public var subrole: String?
    /// Title → description ladder-lite, capped by the producer.
    public var label: String?
    /// GLOBAL, TOP-LEFT-ORIGIN coordinates (not Cocoa's bottom-left). Nil when the node
    /// declined to answer a frame — walked, but not placeable; the renderer skips
    /// drawing it while still counting.
    public var frame: CGRect?
    public var isEnabled: Bool
    public var isFocused: Bool
    public var category: AXNodeCategory
    public var children: [AXNodeSnapshot]
    /// This node's own subtree size (self + all descendants), computed once at build
    /// time — an equality short-circuit on a big tree without walking it.
    public var subtreeCount: Int

    public init(
        id: AXNodeID,
        role: String,
        subrole: String? = nil,
        label: String? = nil,
        frame: CGRect? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        category: AXNodeCategory,
        children: [AXNodeSnapshot] = []
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.category = category
        self.children = children
        self.subtreeCount = 1 + children.reduce(0) { $0 + $1.subtreeCount }
    }
}

extension AXNodeSnapshot {
    /// Pre-order walk over this node's own subtree — self, then each child in order,
    /// recursively.
    public func forEachNode(_ visit: (AXNodeSnapshot) -> Void) {
        visit(self)
        for child in children { child.forEachNode(visit) }
    }

    /// The same pre-order walk, but each visit also receives the chain of ancestors from
    /// the root down to (not including) the node itself — oldest first.
    public func forEachNode(withAncestors visit: (AXNodeSnapshot, [AXNodeSnapshot]) -> Void) {
        forEachNode(withAncestors: visit, ancestors: [])
    }

    private func forEachNode(
        withAncestors visit: (AXNodeSnapshot, [AXNodeSnapshot]) -> Void,
        ancestors: [AXNodeSnapshot]
    ) {
        visit(self, ancestors)
        let nextAncestors = ancestors + [self]
        for child in children { child.forEachNode(withAncestors: visit, ancestors: nextAncestors) }
    }

    /// The node with this id, and everything under it.
    public func subtree(withID id: AXNodeID) -> AXNodeSnapshot? {
        if self.id == id { return self }
        for child in children {
            if let found = child.subtree(withID: id) { return found }
        }
        return nil
    }
}

extension AXAppSnapshot {
    /// The subtree rooted at `id`, searched across every window. A WINDOW's own id
    /// answers with that window's root.
    public func subtree(withID id: AXNodeID) -> AXNodeSnapshot? {
        for window in windows {
            if window.id == id { return window.root }
            if let root = window.root, let found = root.subtree(withID: id) {
                return found
            }
        }
        return nil
    }
}

/// One window's worth of snapshot — the roster row plus (when the walk budget covered
/// it) the window's own content tree.
public struct AXWindowSnapshot: Sendable, Equatable, Identifiable {
    public var id: AXNodeID
    public var title: String
    public var frame: CGRect?
    public var isMain: Bool
    public var isMinimized: Bool
    /// The walk hit a budget ceiling somewhere in this window — the render is honest
    /// but incomplete.
    public var isTruncated: Bool
    public var root: AXNodeSnapshot?

    public init(
        id: AXNodeID,
        title: String,
        frame: CGRect?,
        isMain: Bool = false,
        isMinimized: Bool = false,
        isTruncated: Bool = false,
        root: AXNodeSnapshot? = nil
    ) {
        self.id = id
        self.title = title
        self.frame = frame
        self.isMain = isMain
        self.isMinimized = isMinimized
        self.isTruncated = isTruncated
        self.root = root
    }
}

/// One process's worth of snapshot — what a single walk publishes.
public struct AXAppSnapshot: Sendable, Equatable {
    public var pid: pid_t
    public var bundleID: String?
    public var appName: String
    /// Front-to-back, matching AX's own window order.
    public var windows: [AXWindowSnapshot]
    public var capturedAt: Date
    public var walkDuration: Duration
    public var nodeCount: Int

    public init(
        pid: pid_t,
        bundleID: String?,
        appName: String,
        windows: [AXWindowSnapshot],
        capturedAt: Date,
        walkDuration: Duration,
        nodeCount: Int
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windows = windows
        self.capturedAt = capturedAt
        self.walkDuration = walkDuration
        self.nodeCount = nodeCount
    }

    /// Equality that ignores capture timing — the shape/content of what was walked, not
    /// when.
    public static func == (lhs: AXAppSnapshot, rhs: AXAppSnapshot) -> Bool {
        lhs.pid == rhs.pid
            && lhs.bundleID == rhs.bundleID
            && lhs.appName == rhs.appName
            && lhs.windows == rhs.windows
            && lhs.nodeCount == rhs.nodeCount
    }
}
