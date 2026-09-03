//
//  OverlayStageView.swift
//  VisionAXBench
//
//  WHAT: The image and its AXTree on ONE canvas, two ordered passes.
//  IN:   BenchModel (image, detection, selection)
//  OUT:  OverlayRenderer
//  PIN:  The image is drawn INSIDE the Canvas through the same ImagePlane the
//        boxes use, never as a SwiftUI .background with its own aspectRatio fit —
//        two independent fits are two chances to disagree, and the disagreement
//        would look exactly like a detection error.
//
import SwiftUI
import VisionAX

struct OverlayStageView: View {
    let model: BenchModel
    let image: CGImage
    let window: AXWindowSnapshot
    var showLabels: Bool
    var palette: OverlayRenderer.Palette = .depth
    var showGroundTruth: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let plane = ImagePlane(bounds: CGRect(
                x: 0, y: 0, width: image.width, height: image.height))
            Canvas { context, size in
                context.draw(
                    Image(decorative: image, scale: 1),
                    in: plane.viewRect(for: plane.bounds, in: size))
                if showGroundTruth, let truth = model.groundTruth {
                    OverlayRenderer.drawGroundTruth(
                        truth, plane: plane, in: &context, size: size)
                }
                OverlayRenderer.draw(
                    window: window, plane: plane, selectedID: model.selectedID,
                    showLabels: showLabels, palette: palette,
                    labels: model.detection?.labels, in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    model.selectNode(
                        at: plane.imagePoint(for: value.location, in: proxy.size))
                })
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
