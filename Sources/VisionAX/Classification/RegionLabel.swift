//
//  RegionLabel.swift
//  VisionAX
//
//  WHAT: The classifier's output vocabulary — index ↔ AX role — and one labelled region.
//  IN:   ClassifierSpec (model sidecar), DatasetWriter (roles.json)
//  OUT:  RegionRelabeler, ProposalMatcher, VisionAXBench
//  PIN:  EVERY ROLE HERE MUST BE ONE MARY ALREADY KNOWS. A role that falls to
//        AXNodeCategory.other loses its label at Mary's walk time and is dropped from
//        every roster; a role Mary has no case for is spoken to the user as "link".
//        So the vocabulary is closed, `validated()` proves it, and index 0 is `none` —
//        the answer that leaves a region as VXRegion, which Mary renders not at all.
//        That is the safe failure, and it is why "none" is a class rather than a
//        confidence test bolted on afterwards.
//

import Foundation

/// Index ↔ role. Index 0 is always `none`; the rest are AX role strings.
public struct RoleVocabulary: Sendable, Equatable {
    /// The label for "this region is not an element I know".
    public static let noneRole = "none"

    public let roles: [String]

    public init(roles: [String]) {
        self.roles = roles
    }

    /// The 22 roles the first classifier predicts, plus `none`.
    ///
    /// Chosen as the intersection of what a web page can produce, what a native AX tree
    /// reports, and what Mary's own tables switch on. Roles Mary knows but that no
    /// screenshot can distinguish (AXMenuBarItem vs AXMenuItem) or that never carry a
    /// visible box of their own (AXWebArea) are deliberately absent.
    public static let standard = RoleVocabulary(roles: [
        noneRole,
        "AXButton",
        "AXLink",
        "AXTextField",
        "AXTextArea",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXComboBox",
        "AXSlider",
        "AXTab",
        "AXMenuItem",
        "AXDisclosureTriangle",
        "AXImage",
        "AXHeading",
        "AXStaticText",
        "AXGroup",
        "AXList",
        "AXTable",
        "AXRow",
        "AXCell",
        "AXScrollArea",
        "AXToolbar",
    ])

    public var classCount: Int { roles.count }

    public func role(at index: Int) -> String? {
        guard roles.indices.contains(index) else { return nil }
        return roles[index]
    }

    public func index(of role: String) -> Int? {
        roles.firstIndex(of: role)
    }

    /// True for index 0 — the class that leaves a region unnamed.
    public func isNone(_ index: Int) -> Bool { index == 0 }

    /// Throws unless the table is one Mary can consume: `none` first, no duplicates, and
    /// every role landing somewhere other than `.other`.
    @discardableResult
    public func validated() throws -> RoleVocabulary {
        guard roles.count >= 2 else {
            throw RoleVocabularyError.tooFewClasses(roles.count)
        }
        guard roles.first == Self.noneRole else {
            throw RoleVocabularyError.firstClassIsNotNone(roles.first ?? "")
        }
        var seen = Set<String>()
        for role in roles where !seen.insert(role).inserted {
            throw RoleVocabularyError.duplicateRole(role)
        }
        for role in roles.dropFirst() where AXNodeCategory.category(role: role) == .other {
            throw RoleVocabularyError.roleMaryWouldDiscard(role)
        }
        return self
    }
}

public enum RoleVocabularyError: Error, Equatable, CustomStringConvertible {
    case tooFewClasses(Int)
    case firstClassIsNotNone(String)
    case duplicateRole(String)
    case roleMaryWouldDiscard(String)

    public var description: String {
        switch self {
        case .tooFewClasses(let count):
            return "a vocabulary needs none + at least one role, got \(count) classes"
        case .firstClassIsNotNone(let first):
            return "class 0 must be \"\(RoleVocabulary.noneRole)\", got \"\(first)\""
        case .duplicateRole(let role):
            return "role \"\(role)\" appears twice"
        case .roleMaryWouldDiscard(let role):
            return "role \"\(role)\" categorizes as .other — Mary drops such nodes, "
                + "so predicting it would be worse than predicting nothing"
        }
    }
}

/// One region's answer from the classifier.
public struct RegionLabel: Sendable, Equatable, Codable {
    /// Index into the vocabulary; 0 = none.
    public var classIndex: Int
    /// The vocabulary's role for `classIndex`, resolved at decode time.
    public var role: String
    /// Softmax probability of `classIndex`, 0...1.
    public var confidence: Double

    public init(classIndex: Int, role: String, confidence: Double) {
        self.classIndex = classIndex
        self.role = role
        self.confidence = confidence
    }

    /// True when this is a real role held with enough confidence to publish.
    public func names(atLeast minimumConfidence: Double) -> Bool {
        classIndex != 0 && confidence >= minimumConfidence
    }
}
