//
//  ParameterStrip.swift
//  VisionAXBench
//
//  WHAT: Every engine knob, live. Edits re-run the detection.
//  IN:   BenchModel.options
//  PIN:  These exist because Canny defaults tuned on synthetic rectangles
//        over-segment real screenshots — text especially. Tuning them against
//        real captures is the point of the bench, so nothing here is hidden
//        behind an "advanced" disclosure.
//        IT WRAPS, IT DOES NOT SCROLL. One row of ten controls is wider than
//        the bench's minimum window, and as a horizontal ScrollView that put a
//        scrollbar under the knobs and hid whichever ones did not fit — the
//        two most-tuned parameters could sit offscreen while the strip looked
//        complete. `FlowStrip` spends height only when the width forces it: one
//        row on a wide window, two when narrow, and the image below keeps
//        everything left over.
//
import SwiftUI
import VisionAX

struct ParameterStrip: View {
    @Bindable var model: BenchModel

    var body: some View {
        // SPACING IS WHAT BUYS THE SINGLE ROW. Eleven cells measure about
        // 860pt at 12pt gaps, which fits the detail pane at the bench's
        // minimum window; at 18 they did not, and Reset alone fell to a second
        // row that cost as much height as the knobs above it.
        FlowStrip(horizontalSpacing: 12, verticalSpacing: 6) {
            slider("Low", value: $model.options.lowThreshold, range: 0...255, step: 1)
            slider("High", value: $model.options.highThreshold, range: 0...400, step: 1)
            stepper("Blur", value: $model.options.blurKernel, range: 0...11, step: 2)
            stepper("Close", value: $model.options.closeKernel, range: 0...11, step: 1)
            stepper("Min W", value: $model.options.minWidth, range: 1...200)
            stepper("Min H", value: $model.options.minHeight, range: 1...200)
            slider("Merge IoU", value: $model.options.mergeIOU, range: 0.5...1, step: 0.01)
            stepper("Merge slack", value: $model.options.mergeSlack, range: 0...20)
            stepper("Max depth", value: $model.options.maxDepth, range: 1...64)
            stepper("Max nodes", value: $model.options.maxNodes, range: 1...20000, step: 100)
            Button("Reset") { model.resetOptions() }
                .padding(.top, 12)
        }
        // Small controls throughout: this is a dense instrument panel, and the
        // height saved per row is height the image gets instead.
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func slider(
        _ title: String, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(title)  \(value.wrappedValue.formatted(.number.precision(.fractionLength(step < 1 ? 2 : 0)).grouping(.never)))")
                .font(.caption2.monospacedDigit())
            Slider(value: value, in: range, step: step)
                .frame(width: 120)
        }
    }

    private func stepper(
        _ title: String, value: Binding<Int>,
        range: ClosedRange<Int>, step: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(title)  \(value.wrappedValue)")
                .font(.caption2.monospacedDigit())
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }
}

// MARK: - The layout

/// A left-aligned row of controls that wraps onto as many rows as the current
/// width needs, and reports exactly that height.
///
/// PIN: A `Layout`, not an `HStack` in a `ScrollView` and not a hardcoded pair
///      of rows. The strip's contents are fixed but its width is not — the
///      window resizes — so the row count is a function of the width and only
///      the layout system knows it. Reporting the true height is what keeps the
///      divider under the strip where it belongs instead of over a clipped row.
struct FlowStrip: Layout {
    var horizontalSpacing: CGFloat = 18
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        let rows = self.rows(
            within: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height }
            + verticalSpacing * CGFloat(max(0, rows.count - 1))
        // The proposed width is what the strip occupies when one is offered;
        // an unconstrained proposal falls back to what the content wants.
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Void
    ) {
        var y = bounds.minY
        for row in rows(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                // TOP-ALIGNED WITHIN THE ROW. Every cell is a caption over a
                // control, so their tops line up and their baselines follow;
                // centering would stagger the labels against each other.
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    // MARK: - Breaking into rows

    private struct Item {
        var index: Int
        var size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Greedy left-to-right packing: a control that does not fit starts the
    /// next row. Order is the declaration order, because these knobs are
    /// grouped by what they do and re-ordering them to pack tighter would
    /// scatter that grouping.
    private func rows(within width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let spacing = current.items.isEmpty ? 0 : horizontalSpacing
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row()
            }
            let leading = current.items.isEmpty ? 0 : horizontalSpacing
            current.items.append(Item(index: index, size: size))
            current.width += leading + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
