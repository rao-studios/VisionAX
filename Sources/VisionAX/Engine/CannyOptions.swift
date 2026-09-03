//
//  CannyOptions.swift
//  VisionAX
//
//  WHAT: Swift mirror of vx_canny_options — the whole tunable surface of the engine.
//  IN:   VisionAXBench sliders, callers of VisionEngine.detectRegions
//  OUT:  toC() → vx_canny_options
//  PIN:  `.standard` is seeded from the C default, so the two never disagree.
//

import CVisionAX
import Foundation

public struct CannyOptions: Codable, Sendable, Equatable {
    /// Canny hysteresis thresholds.
    public var lowThreshold: Double
    public var highThreshold: Double
    /// Sobel aperture: 3, 5, or 7.
    public var apertureSize: Int
    /// Gaussian blur kernel before Canny; 0 = none.
    public var blurKernel: Int
    /// Morphological close after Canny, sealing one-pixel gaps; 0 = none.
    public var closeKernel: Int
    public var minWidth: Int
    public var minHeight: Int
    /// A box whose IoU with a larger kept box reaches this is a duplicate.
    public var mergeIOU: Double
    /// Edge-distance tolerance, in pixels, for the same duplicate test.
    public var mergeSlack: Int
    /// Tolerance, in pixels, when deciding "A contains B".
    public var containmentSlack: Int
    /// Sibling reading-order band height.
    public var readingBand: Int
    public var maxDepth: Int
    public var maxNodes: Int

    public init(
        lowThreshold: Double,
        highThreshold: Double,
        apertureSize: Int,
        blurKernel: Int,
        closeKernel: Int,
        minWidth: Int,
        minHeight: Int,
        mergeIOU: Double,
        mergeSlack: Int,
        containmentSlack: Int,
        readingBand: Int,
        maxDepth: Int,
        maxNodes: Int
    ) {
        self.lowThreshold = lowThreshold
        self.highThreshold = highThreshold
        self.apertureSize = apertureSize
        self.blurKernel = blurKernel
        self.closeKernel = closeKernel
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.mergeIOU = mergeIOU
        self.mergeSlack = mergeSlack
        self.containmentSlack = containmentSlack
        self.readingBand = readingBand
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }

    /// The engine's own defaults, read from C so there is one source of truth.
    public static let standard = CannyOptions(vx_canny_options_default())

    init(_ c: vx_canny_options) {
        lowThreshold = c.low_threshold
        highThreshold = c.high_threshold
        apertureSize = Int(c.aperture_size)
        blurKernel = Int(c.blur_kernel)
        closeKernel = Int(c.close_kernel)
        minWidth = Int(c.min_width)
        minHeight = Int(c.min_height)
        mergeIOU = c.merge_iou
        mergeSlack = Int(c.merge_slack)
        containmentSlack = Int(c.containment_slack)
        readingBand = Int(c.reading_band)
        maxDepth = Int(c.max_depth)
        maxNodes = Int(c.max_nodes)
    }

    func toC() -> vx_canny_options {
        var c = vx_canny_options()
        c.low_threshold = lowThreshold
        c.high_threshold = highThreshold
        c.aperture_size = Int32(apertureSize)
        c.blur_kernel = Int32(blurKernel)
        c.close_kernel = Int32(closeKernel)
        c.min_width = Int32(minWidth)
        c.min_height = Int32(minHeight)
        c.merge_iou = mergeIOU
        c.merge_slack = Int32(mergeSlack)
        c.containment_slack = Int32(containmentSlack)
        c.reading_band = Int32(readingBand)
        c.max_depth = Int32(maxDepth)
        c.max_nodes = Int32(maxNodes)
        return c
    }
}
