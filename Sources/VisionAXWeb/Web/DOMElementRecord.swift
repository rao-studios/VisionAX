//
//  DOMElementRecord.swift
//  VisionAXWeb
//
//  WHAT: The shape harvest.js returns, and its translation into ground truth.
//  IN:   WebCrawler (evaluateJavaScript -> JSON string)
//  OUT:  GroundTruthElement
//  PIN:  THE JS DOES NOT DECIDE WHAT IS MATCHABLE. It reports what it saw — role,
//        rect, whether the element was on top — and Swift applies the vocabulary and
//        the size floor here, because the vocabulary lives in Swift and a second copy
//        in JavaScript would be one more thing to drift. The provenance fields (tag,
//        ariaRole, inputType, href) ride along untouched so a role mapping can be
//        revised in Python later without re-crawling a single page.
//

import Foundation
import VisionAX

public struct DOMElementRecord: Codable, Sendable, Equatable {
    public var index: Int
    public var role: String
    public var subrole: String?
    public var text: String?
    public var rect: PixelRect
    public var interactive: Bool
    public var enabled: Bool
    public var depth: Int
    public var parent: Int
    public var visible: Bool
    public var tag: String?
    public var ariaRole: String?
    public var inputType: String?
    public var href: String?
    /// Optional so a payload from an older script still decodes.
    public var placeholder: String?
    public var state: [String]?
}

public struct DOMPayload: Codable, Sendable, Equatable {
    public struct Viewport: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int
    }

    public struct Stats: Codable, Sendable, Equatable {
        public var walked: Int
        public var emitted: Int
        public var truncated: Bool
    }

    public var dpr: Double
    public var viewport: Viewport
    public var scrollX: Int
    public var scrollY: Int
    public var documentHeight: Int
    public var url: String
    public var title: String
    public var elements: [DOMElementRecord]
    public var stats: Stats
}

extension DOMPayload {
    /// Ground truth, with `matchable` decided here against the model's vocabulary.
    public func groundTruth(
        vocabulary: RoleVocabulary = .standard,
        imageBounds: PixelRect
    ) -> [GroundTruthElement] {
        elements.map { record in
            let clipped = record.rect.intersection(imageBounds)
            let matchable = record.visible
                && vocabulary.index(of: record.role) != nil
                && clipped.shortSide >= ProposalMatcher.minimumMatchableSide
                && clipped.area > 0
            return GroundTruthElement(
                index: record.index,
                role: record.role,
                subrole: record.subrole,
                text: record.text,
                rect: clipped,
                interactive: record.interactive,
                enabled: record.enabled,
                depth: record.depth,
                parent: record.parent,
                visible: record.visible,
                matchable: matchable,
                tag: record.tag,
                ariaRole: record.ariaRole,
                inputType: record.inputType,
                href: record.href,
                placeholder: record.placeholder,
                state: record.state)
        }
    }
}
