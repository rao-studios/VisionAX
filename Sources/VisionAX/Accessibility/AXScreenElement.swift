//
//  AXScreenElement.swift
//  VisionAX
//
//  WHAT: One published thing from a snapshot — the flat roster row, not a tree node.
//        Twin of Mary's MaryComputerUse/Accessibility/AXScreenElement.swift.
//  OUT:  AXTreeCodable; a future roster over a VisionAX tree
//

import CoreGraphics
import Foundation

/// One resolvable thing on a snapshot, in the shape a roster publishes it.
public struct AXScreenElement: Sendable, Equatable, Identifiable {
    /// 1-based position in reading order over the published list.
    public var ordinal: Int
    /// `AXNodeSnapshot.id` for a walked node, or a synthetic id for a `.scripted` graft.
    public var id: AXNodeID
    /// Which process this came from.
    public var pid: pid_t
    public var appName: String
    public var windowID: AXNodeID
    public var windowTitle: String
    /// The raw AX role, e.g. `AXButton`, or a synthesized role such as `VXRegion`.
    public var role: String
    public var subrole: String?
    public var category: AXNodeCategory
    /// Never empty — unlabeled nodes drop unless they match a declared editor role.
    public var label: String
    /// Global, top-left-origin coordinates, already clipped to the window it came from.
    public var frame: CGRect
    public var isEnabled: Bool
    public var isFocused: Bool
    /// Labeled container/scrollArea/webArea ancestors, oldest first, innermost last,
    /// capped at 4.
    public var containerTrail: [String]

    public init(
        ordinal: Int,
        id: AXNodeID,
        pid: pid_t,
        appName: String,
        windowID: AXNodeID,
        windowTitle: String,
        role: String,
        subrole: String? = nil,
        category: AXNodeCategory,
        label: String,
        frame: CGRect,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        containerTrail: [String] = []
    ) {
        self.ordinal = ordinal
        self.id = id
        self.pid = pid
        self.appName = appName
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.category = category
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.containerTrail = containerTrail
    }

    /// False only for a `.scripted` graft.
    public var isBackedByLiveAX: Bool {
        category != .scripted
    }
}
