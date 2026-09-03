//
//  BenchRootView.swift
//  VisionAXBench
//
//  WHAT: Sidebar outline + parameter strip + one of four stages.
//  IN:   BenchModel
//  OUT:  TreeOutlineView, ParameterStrip, Overlay / Roles / Edge / JSON stages
//  PIN:  The empty state names what to do; a bench that opens blank and stays
//        blank reads as broken rather than idle.
//
import SwiftUI
import VisionAX

struct BenchRootView: View {
    @Bindable var model: BenchModel
    @State private var stage: Stage = .overlay
    @State private var showLabels = true
    @State private var showGroundTruth = false
    @State private var showURLSheet = false

    enum Stage: String, CaseIterable, Identifiable {
        case overlay = "Overlay"
        case roles = "Roles"
        case map = "Page map"
        case edges = "Canny edges"
        case json = "AXTree JSON"
        var id: String { rawValue }

        /// Which stages draw boxes that can carry text.
        var hasLabels: Bool { self == .overlay || self == .roles }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                ParameterStrip(model: model)
                Divider()
                stageContent
                Divider()
                statusBar
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Stage", selection: $stage) {
                    ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 400)
            }
            ToolbarItem {
                Toggle("Labels", isOn: $showLabels)
                    .disabled(!stage.hasLabels)
            }
            ToolbarItem {
                // Only meaningful for a harvested image; there is nothing to compare
                // an arbitrary screenshot against.
                Toggle("Ground truth", isOn: $showGroundTruth)
                    .disabled(model.groundTruth == nil || !stage.hasLabels)
                    .help(model.groundTruth == nil
                          ? "Open an image from a Dataset/images folder to see its ground truth"
                          : "Dashed boxes are what was really on the page")
            }
            ToolbarItem {
                Button("Open URL…") { showURLSheet = true }
            }
            ToolbarItem {
                Button("Open Image…") { model.presentOpenPanel() }
            }
        }
        .sheet(isPresented: $showURLSheet) {
            URLCaptureSheet(model: model)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url: url) }
            }
            return true
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if let window = model.detection?.window {
            TreeOutlineView(model: model, window: window)
        } else if model.image != nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No tree yet", systemImage: "square.on.square.dashed")
            } description: {
                Text("Open a desktop screenshot to detect regions.")
            }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        if let image = model.image, let detection = model.detection {
            switch stage {
            case .overlay:
                OverlayStageView(
                    model: model, image: image, window: detection.window,
                    showLabels: showLabels, showGroundTruth: showGroundTruth)
            case .roles:
                RolesStageView(
                    model: model, image: image, window: detection.window,
                    showLabels: showLabels, showGroundTruth: showGroundTruth)
            case .map:
                MapStageView(model: model, image: image)
            case .edges:
                // Nil only for a detection this bench did not run — it always asks.
                if let edges = detection.edges {
                    EdgeStageView(edges: edges)
                }
            case .json:
                JSONStageView(model: model)
            }
        } else if model.image != nil || model.isCapturingURL {
            // AN OPEN IMAGE WITH NO TREE YET IS NOT AN EMPTY BENCH. Showing the
            // "open an image" prompt here reads as "your file was rejected", which
            // is the one thing that has not happened. The web view is offscreen, so
            // during a URL capture this is the only sign anything is happening.
            VStack(spacing: 10) {
                ProgressView()
                Text(model.isCapturingURL
                     ? "Rendering the page…"
                     : "Detecting regions in \(model.imageName)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Open an image", systemImage: "photo.badge.plus")
            } description: {
                Text("Drop a screenshot here, open one, or render a web page.")
            } actions: {
                Button("Open Image…") { model.presentOpenPanel() }
                    .buttonStyle(.borderedProminent)
                Button("Open URL…") { showURLSheet = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Text("Detecting…")
            } else if let error = model.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let detection = model.detection {
                Text(model.imageName).bold()
                Text(verbatim: "\(detection.nodeCount) nodes")
                Text(verbatim: "\(detection.contourCount) contours")
                Text(detection.duration.formatted(.units(allowed: [.milliseconds])))
                if let classified = detection.classificationDuration {
                    Text(verbatim: "classify \(classified.formatted(.units(allowed: [.milliseconds])))")
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(detection.namedCount) named")
                        .foregroundStyle(.secondary)
                }
                if detection.window.isTruncated {
                    Label("truncated", systemImage: "scissors")
                        .foregroundStyle(.orange)
                }
                if let node = model.selectedNode, let frame = node.frame {
                    Divider().frame(height: 12)
                    Text(verbatim: "#\(node.id.raw)  \(Int(frame.width))×\(Int(frame.height)) @ \(Int(frame.minX)),\(Int(frame.minY))")
                }
                if let recall = model.groundTruthRecall, recall.overall.total > 0 {
                    Divider().frame(height: 12)
                    Text(verbatim: "truth \(recall.overall.found)/\(recall.overall.total) proposed")
                        .foregroundStyle(.secondary)
                }
                if let match = model.selectedMatch {
                    Divider().frame(height: 12)
                    Text(verbatim: "truth: \(match.label) IoU \(String(format: "%.2f", match.iou))"
                         + (match.element?.text.map { " · \($0.prefix(24))" } ?? ""))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No image open")
            }
            Spacer()
            Text(verbatim: "OpenCV \(model.openCVVersion)").foregroundStyle(.secondary)
            Text(verbatim: "ORT \(model.onnxRuntimeVersion)").foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
