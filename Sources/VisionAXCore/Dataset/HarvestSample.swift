//
//  HarvestSample.swift
//  VisionAXCore
//
//  WHAT: One harvested screen: the ground truth, and the engine's proposals matched to it.
//  IN:   VisionAXHarvestKit (web crawl / app harvest)
//  OUT:  Dataset/samples/<id>.json → Training/visionax_train/dataset.py, bench GT toggle
//  PIN:  BOTH HALVES ARE STORED SEPARATELY ON PURPOSE. `elements` is what was really on
//        screen and `regions` is what Canny proposed; a future detector trains on the
//        first alone, this classifier on the second. Storing only the merged labels
//        would make the detector's dataset unrecoverable without re-harvesting.
//        matchIoU/secondIoU are kept so Python can re-threshold without a new crawl.
//

import Foundation

public enum HarvestSource: String, Codable, Sendable, Equatable {
    case web
    case app
}

/// Where a sample came from — a URL for the crawler, a bundle id for a live app.
public struct HarvestOrigin: Codable, Sendable, Equatable {
    public var url: String?
    public var bundleID: String?
    public var title: String
    /// The generator seed, when the page was synthetic — the whole page is reproducible
    /// from this number alone.
    public var seed: UInt64?

    public init(url: String? = nil, bundleID: String? = nil, title: String, seed: UInt64? = nil) {
        self.url = url
        self.bundleID = bundleID
        self.title = title
        self.seed = seed
    }

    /// The key a train/val split groups on, so one page never lands on both sides.
    public var groupKey: String { url ?? bundleID ?? title }
}

public struct HarvestImageInfo: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Pixels per point, MEASURED (image width ÷ window or viewport width), never assumed.
    public var scale: Double

    public init(width: Int, height: Int, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }
}

public struct HarvestViewport: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var zoom: Double
    public var scrollY: Int

    public init(width: Int, height: Int, zoom: Double = 1, scrollY: Int = 0) {
        self.width = width
        self.height = height
        self.zoom = zoom
        self.scrollY = scrollY
    }
}

/// One element that was really there — the ground truth a proposal is scored against.
public struct GroundTruthElement: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var role: String
    public var subrole: String?
    public var text: String?
    public var rect: PixelRect
    public var interactive: Bool
    public var enabled: Bool
    public var depth: Int
    /// Index of the nearest emitted ancestor, or -1.
    public var parent: Int
    /// Survived clipping and occlusion — a hidden element still ships (a detector may
    /// want the negative) but never claims a proposal.
    public var visible: Bool
    /// Eligible to label a proposal. Producers clear it for invisible, undersized or
    /// out-of-vocabulary elements; ProposalMatcher additionally clears it for a
    /// descendant that duplicates its ancestor's box.
    public var matchable: Bool
    /// Provenance from the DOM, kept so Python can re-map roles without re-harvesting.
    public var tag: String?
    public var ariaRole: String?
    public var inputType: String?
    public var href: String?
    /// A field's placeholder — the name a person reads when the box is empty. Optional
    /// so samples harvested before it existed still decode.
    public var placeholder: String?
    /// checked / selected / expanded / pressed, where the page says so.
    public var state: [String]?

    public var id: Int { index }

    public init(
        index: Int,
        role: String,
        subrole: String? = nil,
        text: String? = nil,
        rect: PixelRect,
        interactive: Bool = false,
        enabled: Bool = true,
        depth: Int = 0,
        parent: Int = -1,
        visible: Bool = true,
        matchable: Bool = true,
        tag: String? = nil,
        ariaRole: String? = nil,
        inputType: String? = nil,
        href: String? = nil,
        placeholder: String? = nil,
        state: [String]? = nil
    ) {
        self.index = index
        self.role = role
        self.subrole = subrole
        self.text = text
        self.rect = rect
        self.interactive = interactive
        self.enabled = enabled
        self.depth = depth
        self.parent = parent
        self.visible = visible
        self.matchable = matchable
        self.tag = tag
        self.ariaRole = ariaRole
        self.inputType = inputType
        self.href = href
        self.placeholder = placeholder
        self.state = state
    }
}

/// What a proposal was decided to be. `ignore` means "do not train on this box" — the
/// evidence was ambiguous, which is different from "nothing is here".
public enum RegionMatchLabel: Sendable, Equatable {
    case role(String)
    case none
    case ignore

    public var roleName: String? {
        if case .role(let role) = self { return role }
        return nil
    }
}

extension RegionMatchLabel: Codable {
    /// One string. AX roles are "AX"-prefixed, so they can never collide with the two
    /// sentinels — which is why this is a bare string and not a tagged object.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "none": self = .none
        case "ignore": self = .ignore
        default: self = .role(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .role(let role): try container.encode(role)
        case .none: try container.encode("none")
        case .ignore: try container.encode("ignore")
        }
    }
}

/// One Canny proposal, and the ground truth it was matched to.
public struct RegionSample: Codable, Sendable, Equatable {
    public var index: Int
    public var parent: Int
    public var depth: Int
    public var rect: PixelRect
    public var label: RegionMatchLabel
    public var matchIoU: Double
    public var matchedElement: Int?
    /// The runner-up, kept because a box whose top two matches are both strong is
    /// exactly the box a re-threshold should reconsider.
    public var secondIoU: Double
    public var secondElement: Int?

    public init(
        index: Int,
        parent: Int,
        depth: Int,
        rect: PixelRect,
        label: RegionMatchLabel,
        matchIoU: Double = 0,
        matchedElement: Int? = nil,
        secondIoU: Double = 0,
        secondElement: Int? = nil
    ) {
        self.index = index
        self.parent = parent
        self.depth = depth
        self.rect = rect
        self.label = label
        self.matchIoU = matchIoU
        self.matchedElement = matchedElement
        self.secondIoU = secondIoU
        self.secondElement = secondElement
    }
}

public struct HarvestSample: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: HarvestSource
    public var origin: HarvestOrigin
    public var image: HarvestImageInfo
    public var scheme: String?
    public var viewport: HarvestViewport?
    public var canny: CannyOptions
    public var engineVersion: String
    public var elements: [GroundTruthElement]
    public var regions: [RegionSample]
    /// Which passes contributed proposals: "canny", and "text" once the text lane's
    /// lines join them. Recorded so a recall number is never compared across runs that
    /// proposed differently — the jump would look like an improvement in detection.
    public var proposalSources: [String]?

    public init(
        id: String,
        source: HarvestSource,
        origin: HarvestOrigin,
        image: HarvestImageInfo,
        scheme: String? = nil,
        viewport: HarvestViewport? = nil,
        canny: CannyOptions,
        engineVersion: String,
        elements: [GroundTruthElement],
        regions: [RegionSample],
        proposalSources: [String]? = nil
    ) {
        self.id = id
        self.source = source
        self.origin = origin
        self.image = image
        self.scheme = scheme
        self.viewport = viewport
        self.canny = canny
        self.engineVersion = engineVersion
        self.elements = elements
        self.regions = regions
        self.proposalSources = proposalSources
    }

    /// The image file this sample describes, relative to the dataset root.
    public var imagePath: String { "images/\(id).png" }
}
