//
//  ProposalMatcher.swift
//  VisionAXCore
//
//  WHAT: Decides what each Canny proposal IS, by matching it against the ground truth.
//  IN:   HarvestSession (engine regions + harvested elements)
//  OUT:  [RegionSample] + refined elements + RecallReport
//  PIN:  THE HARD CASE IS NOT A MISSED BOX, IT IS TWO RIGHT ANSWERS. A link and the
//        text inside it, a button and its label, a field and the div wrapping it are
//        the SAME rectangle with different roles; max-IoU alone flips between them on a
//        pixel and teaches the model the two are interchangeable. Two rules answer it.
//        First, when an ancestor and a descendant occupy the same box, the one Mary can
//        ACT on survives — by category rank, not by depth. Depth alone was tried and is
//        wrong in both directions: a button outranks the text inside it (ancestor wins)
//        but a text field outranks the layout div wrapping it (descendant wins), and
//        keeping the outer one there hands every form field to a group. Second, a
//        proposal whose top two matches are both strong but disagree becomes `ignore`
//        rather than a coin flip. `ignore` is not `none` — one is "no evidence", the
//        other is "no element".
//

import Foundation

public enum ProposalMatcher {
    /// One Canny box, before it knows what it is.
    public struct Proposal: Sendable, Equatable {
        public var index: Int
        public var parent: Int
        public var depth: Int
        public var rect: PixelRect

        public init(index: Int, parent: Int, depth: Int, rect: PixelRect) {
            self.index = index
            self.parent = parent
            self.depth = depth
            self.rect = rect
        }
    }

    /// The smallest side, in pixels, an element must have to be worth matching.
    ///
    /// Below this the detector's own size floor could not have proposed it anyway, so
    /// counting it would depress proposal recall with boxes nothing was ever going to
    /// find. Both ground-truth producers — the DOM walk and the AX walk — apply it, so
    /// it lives here rather than in either of them.
    public static let minimumMatchableSide = 4

    public struct Thresholds: Codable, Sendable, Equatable {
        /// At or above this IoU a proposal takes the element's role.
        public var positive: Double
        /// Between `positive` and this, a proposal is `ignore` — close enough that
        /// calling it `none` would punish the model for being nearly right.
        public var ignoreFloor: Double
        /// A descendant whose box matches its ancestor's this closely stops being
        /// matchable.
        public var duplicateAncestor: Double

        public init(positive: Double = 0.5, ignoreFloor: Double = 0.3, duplicateAncestor: Double = 0.8) {
            self.positive = positive
            self.ignoreFloor = ignoreFloor
            self.duplicateAncestor = duplicateAncestor
        }

        public static let standard = Thresholds()
    }

    public struct Outcome: Sendable, Equatable {
        public var regions: [RegionSample]
        /// The input elements with `matchable` refined by the ancestor-duplicate rule.
        public var elements: [GroundTruthElement]
        public var recall: RecallReport
    }

    public static func match(
        proposals: [Proposal],
        elements: [GroundTruthElement],
        thresholds: Thresholds = .standard
    ) -> Outcome {
        let refined = refineMatchable(elements, thresholds: thresholds)
        let candidates = refined.filter(\.matchable)

        var regions: [RegionSample] = []
        regions.reserveCapacity(proposals.count)
        // Which candidates some proposal covered well enough to count as found.
        var found = Set<Int>()

        for proposal in proposals {
            var bestIoU = 0.0
            var bestIndex: Int?
            var secondIoU = 0.0
            var secondIndex: Int?

            for element in candidates {
                let iou = proposal.rect.intersectionOverUnion(element.rect)
                guard iou > 0 else { continue }
                if iou > bestIoU {
                    secondIoU = bestIoU
                    secondIndex = bestIndex
                    bestIoU = iou
                    bestIndex = element.index
                } else if iou > secondIoU {
                    secondIoU = iou
                    secondIndex = element.index
                }
            }

            if bestIoU >= thresholds.positive, let bestIndex {
                found.insert(bestIndex)
            }

            let label = decide(
                bestIoU: bestIoU, bestIndex: bestIndex,
                secondIoU: secondIoU, secondIndex: secondIndex,
                elements: refined, thresholds: thresholds)

            regions.append(RegionSample(
                index: proposal.index,
                parent: proposal.parent,
                depth: proposal.depth,
                rect: proposal.rect,
                label: label,
                matchIoU: bestIoU,
                matchedElement: bestIndex,
                secondIoU: secondIoU,
                secondElement: secondIndex))
        }

        return Outcome(
            regions: regions,
            elements: refined,
            recall: recall(candidates: candidates, found: found))
    }

    // MARK: - Rules

    private static func decide(
        bestIoU: Double,
        bestIndex: Int?,
        secondIoU: Double,
        secondIndex: Int?,
        elements: [GroundTruthElement],
        thresholds: Thresholds
    ) -> RegionMatchLabel {
        guard let bestIndex, bestIoU >= thresholds.ignoreFloor else {
            return .none
        }
        guard bestIoU >= thresholds.positive else {
            // Overlapping something real, but not squarely. Neither answer is defensible.
            return .ignore
        }
        let bestRole = elements[roleSlot(bestIndex, in: elements)].role
        if secondIoU >= thresholds.positive, let secondIndex {
            let secondRole = elements[roleSlot(secondIndex, in: elements)].role
            if secondRole != bestRole {
                return .ignore
            }
        }
        return .role(bestRole)
    }

    /// `index` is the element's own id, which equals its slot for every producer here;
    /// the search is the guard against a producer that ever numbers them otherwise.
    private static func roleSlot(_ index: Int, in elements: [GroundTruthElement]) -> Int {
        if elements.indices.contains(index), elements[index].index == index { return index }
        return elements.firstIndex { $0.index == index } ?? 0
    }

    /// How much a role is worth keeping when two elements share a box. Higher wins.
    ///
    /// This is Mary's order of usefulness, not an aesthetic one: something she can
    /// click beats something she can only read, which beats a box that merely groups.
    static func rank(of role: String) -> Int {
        switch AXNodeCategory.category(role: role) {
        case .interactive: return 4
        case .image: return 3
        case .text: return 2
        case .scrollArea, .container, .webArea: return 1
        case .window, .scripted, .other: return 0
        }
    }

    /// Clears `matchable` on the loser of every ancestor/descendant pair that occupies
    /// the same box.
    private static func refineMatchable(
        _ elements: [GroundTruthElement],
        thresholds: Thresholds
    ) -> [GroundTruthElement] {
        var refined = elements
        var slotByIndex: [Int: Int] = [:]
        for (slot, element) in refined.enumerated() { slotByIndex[element.index] = slot }

        for slot in refined.indices {
            guard refined[slot].matchable else { continue }
            var parent = refined[slot].parent
            var hops = 0
            // A malformed parent chain must not spin: the tree is at most as deep as
            // the element count.
            while parent >= 0, hops <= refined.count, let parentSlot = slotByIndex[parent] {
                defer {
                    parent = refined[parentSlot].parent
                    hops += 1
                }
                guard refined[parentSlot].matchable,
                      refined[slot].rect.intersectionOverUnion(refined[parentSlot].rect)
                        >= thresholds.duplicateAncestor
                else { continue }

                let childRank = rank(of: refined[slot].role)
                let parentRank = rank(of: refined[parentSlot].role)
                if childRank > parentRank {
                    // The control inside a wrapper: the wrapper is the one to drop.
                    refined[parentSlot].matchable = false
                } else {
                    // The label inside a button, or a tie: the outer one is the target.
                    refined[slot].matchable = false
                    break
                }
            }
        }
        return refined
    }

    private static func recall(
        candidates: [GroundTruthElement],
        found: Set<Int>
    ) -> RecallReport {
        var byRole: [String: RecallTally] = [:]
        var bySize: [String: RecallTally] = [:]
        var overall = RecallTally()

        for element in candidates {
            let hit = found.contains(element.index)
            overall.total += 1
            if hit { overall.found += 1 }

            var role = byRole[element.role] ?? RecallTally()
            role.total += 1
            if hit { role.found += 1 }
            byRole[element.role] = role

            let bucket = RecallReport.sizeBucket(forShortSide: element.rect.shortSide)
            var size = bySize[bucket] ?? RecallTally()
            size.total += 1
            if hit { size.found += 1 }
            bySize[bucket] = size
        }

        return RecallReport(overall: overall, byRole: byRole, bySize: bySize)
    }
}

// MARK: - Proposals from a detection

extension ProposalMatcher {
    /// The engine's tree as proposals, ROOT EXCLUDED — the root is the image itself and
    /// matches nothing. Pre-order, so index i here is index i everywhere downstream.
    public static func proposals(from window: AXWindowSnapshot) -> [Proposal] {
        guard let root = window.root else { return [] }
        var proposals: [Proposal] = []
        var slotByID: [AXNodeID: Int] = [:]
        root.forEachNode(withAncestors: { node, ancestors in
            guard let frame = node.frame else { return }
            if ancestors.isEmpty {
                // The root occupies no slot; its children point at -1.
                slotByID[node.id] = -1
                return
            }
            let parentSlot = ancestors.last.flatMap { slotByID[$0.id] } ?? -1
            let slot = proposals.count
            slotByID[node.id] = slot
            proposals.append(Proposal(
                index: slot,
                parent: parentSlot,
                depth: ancestors.count,
                rect: PixelRect(rounding: frame)))
        })
        return proposals
    }
}
