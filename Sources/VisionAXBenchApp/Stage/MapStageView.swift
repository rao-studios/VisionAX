//
//  MapStageView.swift
//  VisionAXBench
//
//  WHAT: The page as Mary acts on it — rows by what they afford, groups outlined, and
//        where each name came from.
//  IN:   BenchModel.pageMap
//  OUT:  the answer to "why did it not find the first result"
//  PIN:  A DIFFERENT QUESTION FROM THE ROLES STAGE. Roles asks what the model called a
//        box; this asks what a person could DO with it, which is the question the
//        browsing lane actually puts. A page can be perfectly classified and still be
//        unusable — no groups, so no ordinal, so no "the first one" — and only this
//        stage shows that.
//

import SwiftUI
import VisionAX

struct MapStageView: View {
    @Bindable var model: BenchModel
    let image: CGImage

    var body: some View {
        guard let map = model.pageMap else {
            return AnyView(ContentUnavailableView {
                Label("No map yet", systemImage: "map")
            } description: {
                Text("Run a detection with the text lane on.")
            })
        }
        return AnyView(VStack(spacing: 0) {
            summary(map)
            Divider()
            HStack(spacing: 0) {
                canvas(map)
                Divider()
                listing(map)
            }
        })
    }

    private func summary(_ map: PageMap) -> some View {
        HStack(spacing: 14) {
            Text(verbatim: "\(map.elements.count) rows")
            Text(verbatim: "\(map.actionable.count) actionable")
            Text(verbatim: "\(map.groups.count) groups")
            Text(verbatim: "\(Int((map.labeledFraction * 100).rounded()))% named")
            Spacer()
            ForEach(PageAffordance.allCases, id: \.rawValue) { affordance in
                let count = map.elements.filter { $0.affordance == affordance }.count
                if count > 0 {
                    Label("\(count)", systemImage: "square.fill")
                        .foregroundStyle(Self.color(affordance))
                        .help(affordance.rawValue)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func canvas(_ map: PageMap) -> some View {
        let plane = ImagePlane(
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return GeometryReader { _ in
            Canvas { context, size in
                context.draw(
                    Image(decorative: image, scale: 1),
                    in: plane.viewRect(for: plane.bounds, in: size))
                // Groups first, so rows draw over their own container.
                for group in map.groups {
                    let rect = plane.viewRect(for: group.frame, in: size)
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 3),
                        with: .color(.secondary.opacity(0.6)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    if let title = group.title, rect.height > 24 {
                        context.draw(
                            Text(verbatim: "\(group.kind.rawValue): \(title)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary),
                            at: CGPoint(x: rect.minX + 3, y: rect.minY + 7),
                            anchor: .topLeading)
                    }
                }
                for element in map.elements {
                    let rect = plane.viewRect(for: element.frame, in: size)
                    let color = Self.color(element.affordance)
                    context.stroke(
                        Path(rect), with: .color(color),
                        lineWidth: element.isActionable ? 1.6 : 0.7)
                    guard rect.width > 30, rect.height > 10 else { continue }
                    context.draw(
                        Text(verbatim: element.label.prefix(28) + Self.mark(element.labelSource))
                            .font(.system(size: 9))
                            .foregroundStyle(color),
                        at: CGPoint(x: rect.minX + 2, y: rect.maxY - 6),
                        anchor: .bottomLeading)
                }
            }
        }
    }

    private func listing(_ map: PageMap) -> some View {
        List(map.actionable, id: \.id.raw) { element in
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: element.label)
                    .font(.caption)
                Text(verbatim: "\(element.role ?? "—")  \(element.affordance.rawValue)"
                     + "  via \(element.labelSource.rawValue)"
                     + (element.hints.isEmpty ? "" : "  [\(element.hints.joined(separator: ", "))]"))
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 260)
    }

    /// What each affordance is drawn in. One colour per verb, so a glance says which
    /// rows are pressable and which are only there to be read.
    static func color(_ affordance: PageAffordance) -> Color {
        switch affordance {
        case .press: return .accentColor
        case .fill: return .green
        case .adjust: return .orange
        case .scroll: return .purple
        case .none: return .secondary
        }
    }

    /// A mark for a name nobody wrote.
    static func mark(_ source: PageLabelSource) -> String {
        switch source {
        case .synthesized: return " ·?"
        case .icon: return " ·icon"
        default: return ""
        }
    }
}
