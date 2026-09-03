//
//  RoleLegendView.swift
//  VisionAXBench
//
//  WHAT: Which roles the model found, how many of each, and the colour each is drawn in.
//  IN:   BenchModel.roleCounts
//  OUT:  the Roles stage's trailing rail
//  PIN:  Counts, not just names. "AXStaticText 412, AXButton 3" on a page full of
//        buttons is the fastest read there is on a model that has collapsed toward the
//        majority class — the legend is a diagnostic, not decoration.
//
import SwiftUI
import VisionAX

struct RoleLegendView: View {
    let model: BenchModel

    var body: some View {
        let counts = model.roleCounts
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Roles").font(.caption.bold())
                Spacer()
                Text(verbatim: "\(counts.reduce(0) { $0 + $1.count })")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()

            if counts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.classifier == nil ? "No model loaded" : "Nothing named")
                        .font(.caption.bold())
                    Text(model.classifier == nil
                         ? "Load a classifier spec to name these regions."
                         : "Every region fell below the confidence floor.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(counts, id: \.role) { entry in
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(OverlayRenderer.color(
                                        category: AXNodeCategory.category(role: entry.role)))
                                    .frame(width: 9, height: 9)
                                Text(entry.role)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(verbatim: "\(entry.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 190)
        .background(.thinMaterial)
    }
}
