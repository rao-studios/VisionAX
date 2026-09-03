//
//  URLCaptureSheet.swift
//  VisionAXBench
//
//  WHAT: Type a URL, pick a size and an appearance, get that page as the open image.
//  IN:   BenchRootView (a sheet)
//  OUT:  BenchModel.captureURL
//  PIN:  The viewport and appearance are offered rather than assumed because they are
//        two of the three things that change what the detector sees — a page at 1280
//        is a different LAYOUT than at 1920, and in dark mode it is different EDGES,
//        which is what Canny actually works on. Anyone tuning thresholds needs to move
//        between them without leaving the bench.
//
import SwiftUI
import VisionAXWeb

struct URLCaptureSheet: View {
    @Bindable var model: BenchModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var viewport = Viewport.standard
    @State private var scheme: PageTheme.Scheme = .light
    @FocusState private var addressFocused: Bool

    enum Viewport: String, CaseIterable, Identifiable {
        case standard = "1280 × 800"
        case wide = "1440 × 900"
        case full = "1920 × 1080"
        var id: String { rawValue }

        var size: CGSize {
            switch self {
            case .standard: return CGSize(width: 1280, height: 800)
            case .wide: return CGSize(width: 1440, height: 900)
            case .full: return CGSize(width: 1920, height: 1080)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open a web page")
                .font(.headline)
            Text("The page is rendered with the same crawler the harvester uses, so its "
                 + "DOM comes back as ground truth alongside the screenshot.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("example.com", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(capture)

            HStack(spacing: 18) {
                Picker("Size", selection: $viewport) {
                    ForEach(Viewport.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 190)
                Picker("Appearance", selection: $scheme) {
                    Text("Light").tag(PageTheme.Scheme.light)
                    Text("Dark").tag(PageTheme.Scheme.dark)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            HStack {
                if model.isCapturingURL {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Capture", action: capture)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isCapturingURL)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { addressFocused = true }
    }

    private func capture() {
        let address = text
        let size = viewport.size
        let appearance = scheme
        dismiss()
        Task { await model.captureURL(address, viewport: size, scheme: appearance) }
    }
}
