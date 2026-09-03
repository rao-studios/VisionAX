//
//  HarvestSession.swift
//  VisionAXHarvestKit
//
//  WHAT: One run's worth of harvesting — detect, match, write, tally.
//  IN:   WebCrawler / AppHarvester (an image plus what was really on it)
//  OUT:  Dataset/ via DatasetWriter, and a running RecallReport
//  PIN:  THE ENGINE RUNS AT HARVEST TIME, not at training time, and the proposals are
//        stored. That costs disk, and buys two things worth more: the exact boxes the
//        model will be asked about in production are the boxes it trains on, and the
//        recall table below is computed against real proposals rather than assumed.
//        The Canny options are written into every sample, so a dataset gathered under
//        one tuning is never silently mixed with another.
//

import CoreGraphics
import CryptoKit
import Foundation
import VisionAX

public final class HarvestSession {
    public let writer: DatasetWriter
    public let options: CannyOptions
    public let vocabulary: RoleVocabulary
    public private(set) var recall = RecallReport()
    public private(set) var written = 0
    public private(set) var skipped = 0

    private let engine: VisionEngine
    private let startedAt = Date()
    private let runID: String
    private let source: HarvestSource

    public init(
        datasetRoot: URL,
        source: HarvestSource,
        options: CannyOptions = .standard,
        vocabulary: RoleVocabulary = .standard
    ) throws {
        self.writer = try DatasetWriter(root: datasetRoot)
        self.source = source
        self.options = options
        self.vocabulary = vocabulary
        self.engine = try VisionEngine()
        self.runID = "\(source.rawValue)-\(Self.timestamp(Date()))"
        try writer.writeRoles(vocabulary)
    }

    /// Detects, matches, writes. Returns this sample's own recall.
    @discardableResult
    public func record(
        id: String,
        image: CGImage,
        groundTruth: [GroundTruthElement],
        origin: HarvestOrigin,
        scheme: String? = nil,
        viewport: HarvestViewport? = nil,
        scale: Double
    ) throws -> RecallReport {
        // THE SAME UNION SERVING USES. A text line with no border is invisible to the
        // edge pass and perfectly legible to recognition; adding those boxes only at
        // inference would train the head on a proposal set it never meets. Both paths
        // call `TextLines.proposals`, so what is learned is what is asked.
        var detection = try engine.detectRegions(
            in: image, title: origin.title, options: options)
        var sources = ["canny"]
        if let runs = try? TextRecognizer.runs(in: image) {
            let grown = ProposalUnion.union(detection, textRuns: runs)
            if grown.nodeCount != detection.nodeCount {
                detection = grown
                sources.append("text")
            }
        }
        let outcome = ProposalMatcher.match(
            proposals: ProposalMatcher.proposals(from: detection.window),
            elements: groundTruth)

        let sample = HarvestSample(
            id: id,
            source: source,
            origin: origin,
            image: HarvestImageInfo(width: image.width, height: image.height, scale: scale),
            scheme: scheme,
            viewport: viewport,
            canny: options,
            engineVersion: VisionAX.version,
            elements: outcome.elements,
            regions: outcome.regions,
            proposalSources: sources)

        try writer.write(sample: sample, image: image)
        written += 1
        recall = recall.merged(with: outcome.recall)
        return outcome.recall
    }

    public func skip() {
        skipped += 1
    }

    /// Records the run in the manifest. Safe to call repeatedly.
    public func finish() throws {
        try writer.appendRun(DatasetManifest.Run(
            id: runID,
            source: source,
            startedAt: startedAt,
            count: written,
            canny: options,
            recall: recall))
    }

    // MARK: - Identity

    /// A stable id for a web shot: the same page at the same size and scroll always
    /// lands on the same file, so re-crawling refreshes rather than duplicates.
    public static func webID(
        url: String, viewport: CGSize, scheme: String, zoom: Double, scrollIndex: Int,
        seed: UInt64?
    ) -> String {
        let key = "\(url)|\(Int(viewport.width))x\(Int(viewport.height))|\(scheme)|\(zoom)|\(scrollIndex)|\(seed.map(String.init) ?? "-")"
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "web-\(hex.prefix(12))"
    }

    /// An app sample is a moment, not a coordinate — every capture is its own row.
    public static func appID(bundleID: String, at moment: Date = Date()) -> String {
        let safe = bundleID.replacingOccurrences(of: ".", with: "-")
        return "app-\(safe)-\(timestamp(moment))"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
