//
//  BenchModel.swift
//  VisionAXBench
//
//  WHAT: One image, one options set, one detection, its labels, and the JSON.
//  IN:   the open panel, a dropped file, a URL, a launch argument, the sliders
//  OUT:  BenchRootView and every stage
//  PIN:  The JSON is DECODED BACK every run and compared to the tree it came from.
//        A bench that only shows JSON proves it can be written; the round-trip badge
//        proves it can be read, which is the half Mary depends on.
//
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionAX
import VisionAXWeb

@MainActor
@Observable
final class BenchModel {
    private(set) var image: CGImage?
    private(set) var imageName: String = ""
    private(set) var detection: VisionDetection?
    /// The page as Mary would act on it. Built beside the detection, from the same run.
    private(set) var pageMap: PageMap?
    private(set) var json: String = ""
    private(set) var roundTripsCleanly = false
    private(set) var isRunning = false
    private(set) var errorText: String?
    var selectedID: AXNodeID?

    /// The loaded model, if any. Nil is a normal state: the bench is useful for tuning
    /// Canny long before a classifier exists.
    /// What was really on screen, when that is known — from a dataset sample beside
    /// the image, or from the DOM of a page captured by URL.
    private(set) var groundTruthElements: [GroundTruthElement]?
    /// The truth matched against the CURRENT detection. Rebuilt on every run, so it
    /// stays honest while the Canny sliders move — a stored match would silently
    /// describe boxes that no longer exist.
    private(set) var groundTruth: HarvestSample?
    private(set) var groundTruthOrigin: HarvestOrigin?

    /// A URL capture in flight. The web view is offscreen, so this is the only sign.
    private(set) var isCapturingURL = false

    private(set) var classifier: RegionClassifier?
    private(set) var classifierName: String?
    private(set) var classifierError: String?

    /// Dragging this re-thresholds the answers already in hand — no model re-runs.
    var minimumConfidence: Double = 0.5 {
        didSet {
            guard minimumConfidence != oldValue else { return }
            applyThreshold()
        }
    }

    /// Edits re-run the engine; each edit supersedes the last still-pending run.
    var options: CannyOptions = .standard {
        didSet {
            guard options != oldValue else { return }
            scheduleRun()
        }
    }

    private let engine: VisionEngine?
    private var runToken = 0

    init() {
        engine = try? VisionEngine()
        if engine == nil {
            errorText = "The vision engine could not be created."
        }
        loadBundledClassifier()
        loadLaunchArgumentClassifier()
    }

    var openCVVersion: String { VisionAX.openCVVersion }
    var onnxRuntimeVersion: String { VisionAX.onnxRuntimeVersion ?? "unavailable" }

    // MARK: - The model

    /// A model shipped in the package resources is used without being asked for; one
    /// that is present but broken is reported rather than ignored.
    private func loadBundledClassifier() {
        do {
            if let bundled = try RegionClassifier.bundled() {
                adopt(bundled, name: "bundled")
            }
        } catch {
            classifierError = String(describing: error)
        }
    }

    /// `--model <spec.json>` or `VISIONAX_MODEL`, the same shape as `--image`, so a
    /// script can put a specific model in front of the bench without clicking. Wins
    /// over the bundled one: an explicit choice beats a default.
    private func loadLaunchArgumentClassifier() {
        let arguments = CommandLine.arguments
        var path: String?
        if let flag = arguments.firstIndex(of: "--model"), flag + 1 < arguments.count {
            path = arguments[flag + 1]
        } else if let fromEnvironment = ProcessInfo.processInfo.environment["VISIONAX_MODEL"] {
            path = fromEnvironment
        }
        guard let path, !path.isEmpty else { return }
        do {
            let url = URL(fileURLWithPath: path)
            adopt(try RegionClassifier(specURL: url), name: url.lastPathComponent)
        } catch {
            classifierError = String(describing: error)
        }
    }

    func presentModelPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a classifier spec (region-classifier.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            adopt(try RegionClassifier(specURL: url), name: url.lastPathComponent)
        } catch {
            classifierError = String(describing: error)
        }
    }

    private func adopt(_ loaded: RegionClassifier, name: String) {
        classifier = loaded
        classifierName = name
        classifierError = nil
        minimumConfidence = loaded.minimumConfidence
        scheduleRun()
    }

    // MARK: - Opening

    /// `./scripts/bench.sh some/image.png` opens straight onto that file, arriving
    /// here as `--image <path>` or `VISIONAX_IMAGE`; `--url <address>` or
    /// `VISIONAX_URL` renders a page instead.
    ///
    /// NEVER A BARE ARGUMENT. AppKit reads unflagged argv entries as documents to
    /// open; an app with no registered document type then opens NOTHING — the
    /// process runs a normal event loop with zero windows, which looks exactly like
    /// a hang. A flag keeps the argument in the defaults domain where it is inert.
    func openLaunchArgumentImage() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--url"), flag + 1 < arguments.count {
            let address = arguments[flag + 1]
            Task { await captureURL(address) }
            return
        }
        if let address = ProcessInfo.processInfo.environment["VISIONAX_URL"], !address.isEmpty {
            Task { await captureURL(address) }
            return
        }

        var path: String?
        if let flag = arguments.firstIndex(of: "--image"), flag + 1 < arguments.count {
            path = arguments[flag + 1]
        } else if let fromEnvironment = ProcessInfo.processInfo.environment["VISIONAX_IMAGE"] {
            path = fromEnvironment
        }
        guard let path, !path.isEmpty else { return }
        open(url: URL(fileURLWithPath: path))
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a desktop screenshot"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            errorText = "\(url.lastPathComponent) could not be read as an image."
            return
        }
        image = decoded
        imageName = url.lastPathComponent
        selectedID = nil
        errorText = nil
        adoptGroundTruth(Self.loadGroundTruth(besideImageAt: url))
        scheduleRun()
    }

    /// A dataset lays out images/<id>.png beside samples/<id>.json, so opening the
    /// picture is enough to find what was really on it. Any other image simply has none.
    private static func loadGroundTruth(besideImageAt url: URL) -> HarvestSample? {
        let id = url.deletingPathExtension().lastPathComponent
        let candidate = url
            .deletingLastPathComponent()      // images/
            .deletingLastPathComponent()      // dataset root
            .appendingPathComponent("samples/\(id).json")
        guard let data = try? Data(contentsOf: candidate) else { return nil }
        return try? AXTreeJSON.decode(HarvestSample.self, from: data)
    }

    private func adoptGroundTruth(_ sample: HarvestSample?) {
        groundTruthElements = sample?.elements
        groundTruthOrigin = sample?.origin
        groundTruth = nil
    }

    /// Matches the known truth against the detection just produced.
    ///
    /// Deliberately re-run per detection rather than stored: the sliders change which
    /// boxes exist, and a match computed against a previous set would point at regions
    /// that are gone.
    private func matchGroundTruth(to detection: VisionDetection) {
        guard let elements = groundTruthElements, let image else {
            groundTruth = nil
            return
        }
        let outcome = ProposalMatcher.match(
            proposals: ProposalMatcher.proposals(from: detection.window),
            elements: elements)
        groundTruth = HarvestSample(
            id: imageName,
            source: groundTruthOrigin?.bundleID == nil ? .web : .app,
            origin: groundTruthOrigin ?? HarvestOrigin(title: imageName),
            image: HarvestImageInfo(width: image.width, height: image.height, scale: 1),
            canny: detection.options,
            engineVersion: VisionAX.version,
            elements: outcome.elements,
            regions: outcome.regions)
        groundTruthRecall = outcome.recall
    }

    /// How much of the truth this detection actually proposed a box for — the ceiling
    /// on anything the classifier could then name.
    private(set) var groundTruthRecall: RecallReport?

    /// What the matcher decided about the box under the selection.
    var selectedMatch: (label: String, iou: Double, element: GroundTruthElement?)? {
        guard let groundTruth, let selectedID,
              let detection,
              let root = detection.window.root
        else { return nil }

        // Region index is pre-order position with the root excluded, the same order
        // ProposalMatcher.proposals produced.
        var slot = -1
        var found: Int?
        root.forEachNode(withAncestors: { node, ancestors in
            guard !ancestors.isEmpty else { return }
            slot += 1
            if node.id == selectedID { found = slot }
        })
        guard let found, found < groundTruth.regions.count else { return nil }
        let region = groundTruth.regions[found]
        let element = region.matchedElement.flatMap { index in
            groundTruth.elements.first { $0.index == index }
        }
        let name: String
        switch region.label {
        case .role(let role): name = role
        case .none: name = "none"
        case .ignore: name = "ignore"
        }
        return (name, region.matchIoU, element)
    }

    // MARK: - Opening a URL

    /// Renders a page and uses the result as the open image, with the page's own DOM
    /// as ground truth. The same crawler the harvester runs on, so what the bench shows
    /// is what a harvest of that URL would record.
    func captureURL(
        _ text: String,
        viewport: CGSize = CGSize(width: 1280, height: 800),
        scheme: PageTheme.Scheme = .light
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A bare host is what people type; without a scheme URL() yields a relative
        // reference that loads nothing and reports no error.
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host() != nil else {
            errorText = "\(trimmed) is not a URL."
            return
        }

        isCapturingURL = true
        defer { isCapturingURL = false }
        errorText = nil

        do {
            // Offscreen: a browser window appearing over the bench would be worse than
            // the ~4% late-paint risk measured on the heaviest page tried.
            let crawler = try WebCrawler(offscreen: true)
            let capture = try await crawler.capture(
                url: url, html: nil,
                shot: CrawlPlan.Shot(
                    viewport: viewport, scheme: scheme, zoom: 1, scrollIndex: 0))

            image = capture.image
            imageName = url.host() ?? normalized
            selectedID = nil
            let bounds = PixelRect(
                x: 0, y: 0, width: capture.image.width, height: capture.image.height)
            groundTruthElements = capture.payload.groundTruth(imageBounds: bounds)
            groundTruthOrigin = HarvestOrigin(
                url: url.absoluteString,
                title: capture.payload.title.isEmpty ? (url.host() ?? "") : capture.payload.title)
            groundTruth = nil
            scheduleRun()
        } catch {
            errorText = "\(url.host() ?? normalized): \(error)"
        }
    }

    // MARK: - Running

    private func scheduleRun() {
        guard let image, let engine else { return }
        runToken += 1
        let token = runToken
        let options = options
        let title = imageName
        isRunning = true

        let classifier = classifier
        let threshold = minimumConfidence

        Task.detached(priority: .userInitiated) {
            // THE WHOLE PERCEPTION, NOT THE DETECTION ALONE. The bench used to run the
            // detector by itself, which cannot show a page map: the map is the union of
            // Canny boxes, recognized text and geometry, and two of the three are only
            // there when the other lanes run. The edge map is asked for because this is
            // the one caller that draws it.
            let result = Result {
                try engine.perceive(
                    image: image,
                    projection: ScreenProjection(origin: .zero, pixelsPerPoint: 1),
                    options: options,
                    classifier: classifier,
                    lanes: [.regions, .text],
                    title: title,
                    minimumConfidence: threshold,
                    wantsEdgeMap: true)
            }
            await MainActor.run { [weak self] in
                guard let self, token == self.runToken else { return }
                self.applyScene(result)
            }
        }
    }

    /// Re-thresholding is pure, so it happens inline — a slider that hopped onto a
    /// background queue would feel worse and change nothing.
    private func applyThreshold() {
        guard let detection, detection.isClassified else { return }
        apply(.success(detection.relabeled(minimumConfidence: minimumConfidence)))
    }

    private func applyScene(_ result: Result<VisionScene, Error>) {
        switch result {
        case .success(let scene):
            guard let detection = scene.detection else {
                apply(.failure(VisionEngineError.unreadableImage))
                return
            }
            pageMap = scene.pageMap()
            apply(.success(detection))
        case .failure(let error):
            apply(.failure(error))
        }
    }

    private func apply(_ result: Result<VisionDetection, Error>) {
        isRunning = false
        switch result {
        case .success(let detection):
            self.detection = detection
            errorText = nil
            do {
                let encoded = try detection.json()
                json = encoded
                let decoded = try AXTreeJSON.decode(AXWindowSnapshot.self, from: encoded)
                roundTripsCleanly = decoded == detection.window
            } catch {
                json = "// encoding failed: \(error)"
                roundTripsCleanly = false
            }
            if let selectedID, detection.window.root?.subtree(withID: selectedID) == nil {
                self.selectedID = nil
            }
            matchGroundTruth(to: detection)
        case .failure(let error):
            self.detection = nil
            pageMap = nil
            json = ""
            roundTripsCleanly = false
            groundTruth = nil
            errorText = String(describing: error)
        }
    }

    func resetOptions() {
        options = .standard
    }

    /// How many nodes the model actually named, and the roles it used.
    var roleCounts: [(role: String, count: Int)] {
        guard let root = detection?.window.root else { return [] }
        var counts: [String: Int] = [:]
        root.forEachNode { node in
            guard node.role != VisionAX.regionRole, node.role != VisionAX.windowRole else { return }
            counts[node.role, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (role: $0.key, count: $0.value) }
    }

    /// The label behind the selected node, threshold not applied — what the model
    /// actually thought, which is the interesting number when it got one wrong.
    var selectedLabel: RegionLabel? {
        guard let selectedID else { return nil }
        return detection?.labels?[selectedID]
    }

    // MARK: - Selection

    /// Mary's AXHitTest rule: the SMALLEST frame containing the point wins, not the
    /// last drawn — a child that exactly fills its parent is still the better answer.
    func selectNode(at point: CGPoint) {
        guard let root = detection?.window.root else { return }
        var best: AXNodeSnapshot?
        var bestArea = CGFloat.greatestFiniteMagnitude
        root.forEachNode { node in
            guard let frame = node.frame, frame.contains(point) else { return }
            let area = frame.width * frame.height
            guard area < bestArea else { return }
            bestArea = area
            best = node
        }
        selectedID = best?.id
    }

    var selectedNode: AXNodeSnapshot? {
        guard let selectedID else { return nil }
        return detection?.window.root?.subtree(withID: selectedID)
    }

    // MARK: - JSON actions

    func copyJSON() {
        guard !json.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    func saveJSON() {
        guard !json.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue =
            (imageName as NSString).deletingPathExtension + "-axtree.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }
}
