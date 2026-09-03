//
//  RolesStageView.swift
//  VisionAXBench
//
//  WHAT: The same overlay, coloured by what the classifier called each box.
//  IN:   BenchModel (detection + labels + threshold)
//  OUT:  OverlayStageView(palette: .role), RoleLegendView
//  PIN:  The confidence slider re-thresholds answers already in hand — no model runs,
//        so it is smooth at a thousand boxes. When there is no model this stage says
//        so and offers the panel, rather than showing an empty overlay that looks
//        like a classifier which found nothing.
//
import SwiftUI
import VisionAX

struct RolesStageView: View {
    @Bindable var model: BenchModel
    let image: CGImage
    let window: AXWindowSnapshot
    var showLabels: Bool
    var showGroundTruth: Bool = false

    var body: some View {
        if model.classifier == nil {
            ContentUnavailableView {
                Label("No classifier loaded", systemImage: "brain")
            } description: {
                Text(model.classifierError
                     ?? "Load a model spec to name these regions, or train one with Training/.")
            } actions: {
                Button("Load Model…") { model.presentModelPanel() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                confidenceStrip
                Divider()
                HStack(spacing: 0) {
                    OverlayStageView(
                        model: model, image: image, window: window,
                        showLabels: showLabels, palette: .role,
                        showGroundTruth: showGroundTruth)
                    Divider()
                    RoleLegendView(model: model)
                }
            }
        }
    }

    private var confidenceStrip: some View {
        HStack(spacing: 12) {
            Text("Min confidence")
                .font(.caption)
            Slider(value: $model.minimumConfidence, in: 0...1)
                .frame(width: 220)
            Text(verbatim: model.minimumConfidence.formatted(
                .number.precision(.fractionLength(2)).grouping(.never)))
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .leading)

            if let label = model.selectedLabel {
                Divider().frame(height: 12)
                Text(verbatim: "selected: \(label.role) \(String(format: "%.3f", label.confidence))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if let name = model.classifierName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Button("Load Model…") { model.presentModelPanel() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
