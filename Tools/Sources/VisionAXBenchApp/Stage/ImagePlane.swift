//
//  ImagePlane.swift
//  VisionAXBench
//
//  WHAT: Image-pixel space → view space, aspect-fit and letterboxed.
//  IN:   the detection's image bounds + the canvas size
//  OUT:  OverlayStageView, EdgeStageView
//  PIN:  Port of Mary's AXDesktopPlane, minus the Cocoa flip — an image's rows are
//        already top-down, which is the same orientation AX reports. One transform
//        serves both the image and the boxes, so they cannot drift apart.
//
import CoreGraphics
import Foundation

struct ImagePlane: Equatable {
    /// The image's pixel rect. Origin is always zero here, kept general anyway.
    let bounds: CGRect

    static let empty = ImagePlane(bounds: CGRect(x: 0, y: 0, width: 1, height: 1))

    /// Scale + offset that fits `bounds` inside `viewSize`, preserving aspect ratio
    /// and letterboxing the shorter axis.
    func fit(into viewSize: CGSize) -> (scale: CGFloat, offset: CGPoint) {
        guard bounds.width > 0, bounds.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else { return (1, .zero) }
        let scale = min(viewSize.width / bounds.width, viewSize.height / bounds.height)
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale
        let offset = CGPoint(
            x: (viewSize.width - scaledWidth) / 2 - bounds.minX * scale,
            y: (viewSize.height - scaledHeight) / 2 - bounds.minY * scale)
        return (scale, offset)
    }

    /// One image-space rect in view space. Scale + translate only.
    func viewRect(for rect: CGRect, in viewSize: CGSize) -> CGRect {
        let (scale, offset) = fit(into: viewSize)
        return CGRect(
            x: rect.minX * scale + offset.x,
            y: rect.minY * scale + offset.y,
            width: rect.width * scale,
            height: rect.height * scale)
    }

    /// The inverse — a point in the VIEW back to image space, for hit testing.
    func imagePoint(for viewPoint: CGPoint, in viewSize: CGSize) -> CGPoint {
        let (scale, offset) = fit(into: viewSize)
        guard scale > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - offset.x) / scale, y: (viewPoint.y - offset.y) / scale)
    }
}
