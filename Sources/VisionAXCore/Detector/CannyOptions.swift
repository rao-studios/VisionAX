//
//  CannyOptions.swift
//  VisionAXCore
//
//  WHAT: The detector's whole tunable surface, as a value — what a dataset sample records
//        about the proposals it was built from.
//  IN:   HarvestSample, DatasetManifest.Run; Frigate's VisionAX engine and the bench sliders
//  OUT:  JSON in every sample and run; Frigate's CannyOptions extension → vx_canny_options
//  PIN:  THE VALUE LIVES HERE, THE DEFAULTS DO NOT. `.standard` is read from the C engine
//        (`vx_canny_options_default()`) so the two can never disagree, which is why it is
//        declared beside the engine in Frigate and not in this dependency-free module.
//        A sample records the options it was proposed with, so a recall number is never
//        compared across detectors that were tuned differently.
//

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
}
