//
//  OverlayRenderer.swift
//  VisionAXBench
//
//  WHAT: The AXTree drawn as labelled boxes over the image it came from.
//  IN:   OverlayStageView (one Canvas pass, after the image)
//  OUT:  GraphicsContext strokes
//  PIN:  Two palettes, because the two stages answer different questions. Unclassified,
//        every region is `.other`, so a category palette would paint one flat colour
//        and hide the nesting that IS the result — depth drives the hue there. Once a
//        classifier has run, the ROLE is the result and depth is the distraction, so
//        the Roles stage colours by Mary's own category families (the same families
//        Sand's WireframeRenderer strokes). Port of Mary's SandStageOverlay.drawRect
//        and WireframeRenderer's label threshold.
//
import SwiftUI
import VisionAX

enum OverlayRenderer {

    /// What the hue means.
    enum Palette {
        /// Nesting ring — the answer when nothing has a role yet.
        case depth
        /// Mary's category families — the answer once a classifier has spoken.
        case role
    }

    /// Below this on-screen size a label is noise, not information — Mary's
    /// WireframeRenderer thresholds.
    static let labelWidthThreshold: CGFloat = 28
    static let labelHeightThreshold: CGFloat = 12

    /// A real screenshot yields ~1,000 boxes, and every label is a text layout inside
    /// the Canvas pass. Past this many the frame time is visible on a slider drag, so
    /// the largest boxes keep their labels and the rest go quiet.
    static let labelBudget = 300

    /// One hue per depth ring, cycling. Depth 0 is the image root.
    static let depthColors: [Color] = [.secondary, .blue, .green, .orange, .purple, .pink, .teal]

    static func color(depth: Int) -> Color {
        depthColors[depth % depthColors.count]
    }

    /// The stroke family for a node's category — the same split Sand draws AX trees by.
    static func color(category: AXNodeCategory) -> Color {
        switch category {
        case .interactive: return .accentColor
        case .text: return .green
        case .image: return .purple
        case .container: return .orange
        case .scrollArea: return .teal
        case .webArea: return .blue
        case .scripted: return .pink
        case .window: return .secondary
        case .other: return .gray
        }
    }

    /// The harvested truth, drawn under the proposals: dashed, by category, unfilled.
    /// Dashed because the eye must be able to tell at a glance which boxes came from
    /// the detector and which from the page itself — that comparison is the entire
    /// point of the overlay.
    static func drawGroundTruth(
        _ sample: HarvestSample,
        plane: ImagePlane,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for element in sample.elements where element.matchable {
            let rect = plane.viewRect(for: element.rect.cgRect, in: size)
            guard rect.width > 1, rect.height > 1 else { continue }
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 2),
                with: .color(color(category: AXNodeCategory.category(role: element.role))
                    .opacity(0.65)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    static func draw(
        window: AXWindowSnapshot,
        plane: ImagePlane,
        selectedID: AXNodeID?,
        showLabels: Bool,
        palette: Palette = .depth,
        labels: [AXNodeID: RegionLabel]? = nil,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let root = window.root else { return }
        // Which boxes may carry text: the biggest ones, chosen once per frame rather
        // than per node, so the choice is stable while a slider moves.
        var labelled: Set<AXNodeID> = []
        if showLabels {
            var sized: [(AXNodeID, CGFloat)] = []
            root.forEachNode { node in
                if let frame = node.frame { sized.append((node.id, frame.width * frame.height)) }
            }
            labelled = Set(sized.sorted { $0.1 > $1.1 }.prefix(labelBudget).map(\.0))
        }
        draw(node: root, depth: 0, plane: plane, selectedID: selectedID,
             labelled: labelled, palette: palette, labels: labels,
             in: &context, size: size)
    }

    private static func draw(
        node: AXNodeSnapshot,
        depth: Int,
        plane: ImagePlane,
        selectedID: AXNodeID?,
        labelled: Set<AXNodeID>,
        palette: Palette,
        labels: [AXNodeID: RegionLabel]?,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        if let frame = node.frame, frame.width > 0, frame.height > 0 {
            let rect = plane.viewRect(for: frame, in: size)
            let isSelected = node.id == selectedID
            let isRoot = depth == 0
            let named = node.role != VisionAX.regionRole
            let stroke: Color = switch palette {
            case .depth: color(depth: depth)
            case .role: color(category: node.category)
            }
            drawRect(
                rect,
                label: labelled.contains(node.id) ? caption(for: node, palette: palette, labels: labels) : "",
                color: isSelected ? .yellow : stroke,
                dashed: isRoot,
                // In the Roles stage an unnamed box is background: thin and grey, so
                // the eye goes to what the model actually recognised.
                lineWidth: isSelected ? 2.5 : (isRoot ? 1.5 : (palette == .role && !named ? 0.6 : 1.2)),
                filled: isSelected,
                opacity: palette == .role && !named && !isSelected ? 0.35 : 0.9,
                in: &context)
        }
        // Parent first, children after: the painter's order Mary uses, so a child
        // never hides under the container that holds it.
        for child in node.children {
            draw(node: child, depth: depth + 1, plane: plane, selectedID: selectedID,
                 labelled: labelled, palette: palette, labels: labels,
                 in: &context, size: size)
        }
    }

    private static func caption(
        for node: AXNodeSnapshot,
        palette: Palette,
        labels: [AXNodeID: RegionLabel]?
    ) -> String {
        switch palette {
        case .depth:
            return "\(node.label ?? node.role) #\(node.id.raw)"
        case .role:
            // An unnamed box says nothing rather than "VXRegion" a thousand times.
            guard node.role != VisionAX.regionRole else { return "" }
            guard let confidence = labels?[node.id]?.confidence else { return node.role }
            return "\(node.role) \(String(format: "%.2f", confidence))"
        }
    }

    private static func drawRect(
        _ rect: CGRect,
        label: String,
        color: Color,
        dashed: Bool,
        lineWidth: CGFloat,
        filled: Bool,
        opacity: Double = 0.9,
        in context: inout GraphicsContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = Path(roundedRect: rect, cornerRadius: 3)
        if filled {
            context.fill(path, with: .color(color.opacity(0.15)))
        }
        context.stroke(
            path, with: .color(color.opacity(opacity)),
            style: StrokeStyle(lineWidth: lineWidth, dash: dashed ? [4, 3] : []))

        guard !label.isEmpty,
              rect.width >= labelWidthThreshold,
              rect.height >= labelHeightThreshold
        else { return }
        // Below the box, the way Mary anchors its marks, so the label never
        // occludes what the box contains.
        context.draw(
            Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(color),
            at: CGPoint(x: rect.minX + 2, y: rect.maxY + 2),
            anchor: .topLeading)
    }
}
