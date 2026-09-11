//
//  PixelRect.swift
//  VisionAXCore
//
//  WHAT: An integer rect in image-pixel space, and the geometry the matcher needs.
//  IN:   harvest.js rects, AXWalker frames, engine regions
//  OUT:  HarvestSample, ProposalMatcher
//  PIN:  INTEGERS, because this is what lands in the dataset JSON and a training run
//        must be able to compare two harvests byte for byte. The tree keeps CGFloat;
//        the dataset rounds ONCE, here, at the boundary.
//

import CoreGraphics
import Foundation

public struct PixelRect: Codable, Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Rounds a CGRect the way the dataset stores it: origin rounded, far edge rounded,
    /// size taken as the difference — so a rect never grows or shrinks by two pixels
    /// because each edge rounded independently.
    public init(rounding rect: CGRect) {
        let minX = Int(rect.minX.rounded())
        let minY = Int(rect.minY.rounded())
        let maxX = Int(rect.maxX.rounded())
        let maxY = Int(rect.maxY.rounded())
        self.init(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    public var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var area: Int { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    /// The shorter side — what a size-bucket and a minimum-extent test are about.
    public var shortSide: Int { min(width, height) }

    public func intersection(_ other: PixelRect) -> PixelRect {
        let minX = max(x, other.x)
        let minY = max(y, other.y)
        let maxX = min(self.maxX, other.maxX)
        let maxY = min(self.maxY, other.maxY)
        return PixelRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Intersection over union; 0 when either rect is empty.
    public func intersectionOverUnion(_ other: PixelRect) -> Double {
        let a = area
        let b = other.area
        guard a > 0, b > 0 else { return 0 }
        let overlap = intersection(other).area
        let union = a + b - overlap
        return union > 0 ? Double(overlap) / Double(union) : 0
    }

    /// True when `other` sits inside this rect, allowing `slack` pixels of spill.
    public func contains(_ other: PixelRect, slack: Int = 0) -> Bool {
        other.x >= x - slack
            && other.y >= y - slack
            && other.maxX <= maxX + slack
            && other.maxY <= maxY + slack
    }

    /// The fraction of `self` that survives clipping to `bounds`.
    public func visibleFraction(clippedTo bounds: PixelRect) -> Double {
        guard area > 0 else { return 0 }
        return Double(intersection(bounds).area) / Double(area)
    }
}
