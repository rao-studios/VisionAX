//
//  TreeOutlineView.swift
//  VisionAXBench
//
//  WHAT: The tree, top-down, as the outline it is meant to be traversed as.
//  IN:   BenchModel.detection
//  OUT:  selection, shared with the overlay stage
//  PIN:  Rows show the frame in image pixels, not view points — what the JSON
//        will carry, not what the screen happens to be showing. Every readout is
//        `Text(verbatim:)`: a localized Text turns 1920 into "1,920", which is
//        wrong for a pixel count someone is about to compare against JSON.
//
import SwiftUI
import VisionAX

struct TreeOutlineView: View {
    let model: BenchModel
    let window: AXWindowSnapshot
    /// Depth per node, walked ONCE per tree. Resolving depth inside the row body
    /// instead would walk the whole tree for every row drawn — 978 nodes on a real
    /// screenshot turns a scroll into a million comparisons.
    private let depths: [AXNodeID: Int]

    init(model: BenchModel, window: AXWindowSnapshot) {
        self.model = model
        self.window = window
        var depths: [AXNodeID: Int] = [:]
        window.root?.forEachNode(withAncestors: { node, ancestors in
            depths[node.id] = ancestors.count
        })
        self.depths = depths
    }

    var body: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { model.selectedID = $0 })
        ) {
            if let root = window.root {
                OutlineGroup([root], id: \.id, children: \.optionalChildren) { node in
                    row(node)
                        .tag(node.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ node: AXNodeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(OverlayRenderer.color(depth: depths[node.id] ?? 0))
                    .frame(width: 7, height: 7)
                Text(node.label ?? node.role)
                    .font(.system(size: 11, weight: .medium))
                Text(verbatim: "#\(node.id.raw)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let frame = node.frame {
                Text(verbatim: "\(Int(frame.width))×\(Int(frame.height)) @ \(Int(frame.minX)),\(Int(frame.minY))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension AXNodeSnapshot {
    /// `OutlineGroup` wants nil, not [], for a leaf — an empty array draws a
    /// disclosure triangle over nothing.
    var optionalChildren: [AXNodeSnapshot]? {
        children.isEmpty ? nil : children
    }
}
