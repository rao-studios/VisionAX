//
//  HarvestRootView.swift
//  VisionAXHarvest
//
//  WHAT: What the harvester is doing right now — the log, the last shot, the recall.
//  IN:   HarvestModel
//  OUT:  a window worth leaving open
//  PIN:  The recall table is on screen the whole time, not printed at the end, because
//        it is the number that decides whether to keep crawling or go tune Canny.
//

import SwiftUI
import VisionAX
import VisionAXHarvestKit
import VisionAXWeb

struct HarvestRootView: View {
    @Bindable var model: HarvestModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                logList
            }
            .frame(minWidth: 460)

            VStack(spacing: 0) {
                preview
                Divider()
                recallTable
            }
            .frame(minWidth: 320)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.progress.isEmpty ? "VisionAX Harvest" : model.progress)
                    .font(.headline)
                Text(verbatim: "\(model.written) written · \(model.skipped) skipped · \(model.datasetPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                Button("Stop") { model.stop() }
            } else {
                Button("Start") { Task { await model.start() } }
            }
        }
        .padding(12)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(model.log) { line in
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(line.isProblem ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                    .id(line.id)
            }
            .onChange(of: model.log.count) {
                if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = model.lastImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView {
                Label("No capture yet", systemImage: "camera.viewfinder")
            } description: {
                Text(model.permissions.isReady
                     ? "The last harvested screen appears here."
                     : model.permissions.missingDescription)
            }
        }
    }

    private var recallTable: some View {
        ScrollView {
            Text(model.recall.overall.total == 0
                 ? "No ground truth matched yet."
                 : model.recall.formattedTable())
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(height: 240)
    }
}
