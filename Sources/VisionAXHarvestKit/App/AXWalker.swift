//
//  AXWalker.swift
//  VisionAXHarvestKit
//
//  WHAT: A pre-order walk of one window's accessibility tree, budgeted.
//  IN:   AppHarvester
//  OUT:  [WalkedNode] -> GroundTruthElement
//  PIN:  SELF-CONTAINED ON PURPOSE — VisionAX must not import Mary, so this replicates
//        the walk rather than borrowing it. It reads only what it needs: role and frame
//        always, a label only where the category could carry one, enabled only for
//        interactive nodes. That is not micro-optimisation — every attribute read is a
//        synchronous IPC round trip to another process, and reading four attributes on
//        fifty thousand nodes is the difference between a two-second walk and a
//        thirty-second one, during which the screen is changing underneath the capture.
//

import ApplicationServices
import CoreGraphics
import Foundation
import VisionAX

public struct WalkedNode: Sendable, Equatable {
    public var index: Int
    public var parent: Int
    public var depth: Int
    public var role: String
    public var subrole: String?
    public var label: String?
    /// Global, top-left-origin points, as AX reports them.
    public var frame: CGRect
    public var isEnabled: Bool
}

public struct AXWalkResult: Sendable {
    public var nodes: [WalkedNode]
    public var truncated: Bool
    public var duration: Duration
}

public enum AXWalker {
    public struct Budget: Sendable, Equatable {
        public var maxDepth: Int
        public var maxNodes: Int
        public var deadline: Duration
        public var labelCap: Int

        /// Mary's exhaustive preset: deep enough for a web area, capped so a runaway
        /// tree cannot hold the harvest open forever.
        public static let exhaustive = Budget(
            maxDepth: 64, maxNodes: 50_000, deadline: .seconds(15), labelCap: 200)
    }

    public static func walk(window: AXUIElement, budget: Budget = .exhaustive) -> AXWalkResult {
        var nodes: [WalkedNode] = []
        var truncated = false
        let started = ContinuousClock.now
        let deadline = started.advanced(by: budget.deadline)

        func visit(_ element: AXUIElement, parent: Int, depth: Int) {
            guard !truncated else { return }
            if nodes.count >= budget.maxNodes || ContinuousClock.now >= deadline {
                truncated = true
                return
            }

            let role = AXAttributes.role(element)
            let category = AXNodeCategory.category(role: role)
            guard let frame = AXAttributes.frame(element) else {
                // Walked but not placeable: it cannot be matched to pixels, but its
                // children still can be.
                for child in AXAttributes.children(element, role: role) where depth < budget.maxDepth {
                    visit(child, parent: parent, depth: depth + 1)
                }
                return
            }

            let index = nodes.count
            nodes.append(WalkedNode(
                index: index,
                parent: parent,
                depth: depth,
                role: role,
                subrole: AXAttributes.subrole(element),
                // A node Mary would file under .other never gets its label read, so
                // reading one here would be evidence she will not have.
                label: category == .other ? nil : AXAttributes.label(element, cap: budget.labelCap),
                frame: frame,
                isEnabled: category == .interactive
                    ? (AXAttributes.bool(element, kAXEnabledAttribute as String) ?? true)
                    : true))

            // A node AT the depth limit is kept; its children are withheld. Mary's
            // AXTreeWalker semantics, so a truncated VisionAX tree and a truncated Mary
            // tree are truncated the same way.
            guard depth < budget.maxDepth else {
                truncated = true
                return
            }
            for child in AXAttributes.children(element, role: role) {
                visit(child, parent: index, depth: depth + 1)
            }
        }

        visit(window, parent: -1, depth: 0)
        return AXWalkResult(
            nodes: nodes, truncated: truncated,
            duration: started.duration(to: ContinuousClock.now))
    }

    /// Walked nodes as ground truth, in the capture's pixel space.
    ///
    /// `windowOrigin` is the window's own top-left in global points; `scale` is the
    /// MEASURED pixels-per-point of the capture.
    public static func groundTruth(
        _ result: AXWalkResult,
        windowOrigin: CGPoint,
        scale: Double,
        imageBounds: PixelRect,
        vocabulary: RoleVocabulary = .standard
    ) -> [GroundTruthElement] {
        // A node is only visible where its clipping ancestors agree it is. Computed by
        // index, which works because a parent always precedes its children.
        var clip: [PixelRect] = []
        clip.reserveCapacity(result.nodes.count)
        var elements: [GroundTruthElement] = []
        elements.reserveCapacity(result.nodes.count)

        let clipping: Set<String> = ["AXScrollArea", "AXWebArea", "AXWindow", "AXSheet", "AXDrawer"]

        for node in result.nodes {
            let pixels = PixelRect(rounding: CGRect(
                x: (node.frame.origin.x - windowOrigin.x) * scale,
                y: (node.frame.origin.y - windowOrigin.y) * scale,
                width: node.frame.size.width * scale,
                height: node.frame.size.height * scale))

            let inherited = node.parent >= 0 && node.parent < clip.count
                ? clip[node.parent] : imageBounds
            let visibleRect = pixels.intersection(inherited)
            clip.append(clipping.contains(node.role) ? visibleRect : inherited)

            let category = AXNodeCategory.category(role: node.role)
            // Half of it must survive clipping: a row peeking one pixel out of a scroll
            // area is not something a detector could reasonably be asked to find.
            let visible = pixels.area > 0 && visibleRect.visibleFraction(clippedTo: inherited) >= 0.5
            let matchable = visible
                && vocabulary.index(of: node.role) != nil
                && visibleRect.shortSide >= ProposalMatcher.minimumMatchableSide

            elements.append(GroundTruthElement(
                index: node.index,
                role: node.role,
                subrole: node.subrole,
                text: node.label,
                rect: visibleRect,
                interactive: category == .interactive,
                enabled: node.isEnabled,
                depth: node.depth,
                parent: node.parent,
                visible: visible,
                matchable: matchable))
        }
        return elements
    }
}
