//
//  EdgeStageView.swift
//  VisionAXBench
//
//  WHAT: The raw Canny map, on the same plane as the overlay.
//  IN:   VisionDetection.edges
//  PIN:  Same ImagePlane as the overlay stage, so switching between the two does
//        not move anything — an edge and the box it produced land on the same pixel.
//
import SwiftUI

struct EdgeStageView: View {
    let edges: CGImage

    var body: some View {
        GeometryReader { _ in
            let plane = ImagePlane(bounds: CGRect(
                x: 0, y: 0, width: edges.width, height: edges.height))
            Canvas { context, size in
                context.draw(
                    Image(decorative: edges, scale: 1),
                    in: plane.viewRect(for: plane.bounds, in: size))
            }
        }
        .background(Color.black)
    }
}
