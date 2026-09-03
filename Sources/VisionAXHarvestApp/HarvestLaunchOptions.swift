//
//  HarvestLaunchOptions.swift
//  VisionAXHarvest
//
//  WHAT: The command line, parsed once.
//  IN:   CommandLine.arguments
//  OUT:  HarvestModel
//  PIN:  EVERY OPTION IS FLAGGED. AppKit reads an unflagged argv entry as a document
//        to open, and an app with no registered document type answers by opening no
//        window at all — the process runs a normal event loop, forever, looking
//        exactly like a hang. The bench learned this the hard way; the harvester is
//        born knowing it.
//

import CoreGraphics
import Foundation
import VisionAX
import VisionAXHarvestKit
import VisionAXWeb

struct HarvestLaunchOptions {
    enum Mode: Equatable {
        case idle
        case syntheticWeb(count: Int)
        case urlList(URL)
        case app(bundleID: String)
    }

    var mode: Mode = .idle
    var outputRoot: URL = URL(fileURLWithPath: "Dataset", isDirectory: true)
    var plan = CrawlPlan()
    var seed: UInt64 = 1
    var offscreen = false
    var quitWhenDone = false
    var record = false
    var interval: Double = 3
    /// The detector settings this run harvests under. Written into every sample, so
    /// two runs at different tunings can never be silently mixed.
    var canny: CannyOptions = .standard

    static func parse(_ arguments: [String] = CommandLine.arguments) -> HarvestLaunchOptions {
        var options = HarvestLaunchOptions()
        var viewports = [CGSize(width: 1280, height: 800)]
        var schemes: [PageTheme.Scheme] = [.light]
        var zooms: [Double] = [1.0]
        var scrolls = 1

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        if let count = value(after: "--web-synthetic").flatMap(Int.init) {
            options.mode = .syntheticWeb(count: count)
        } else if let list = value(after: "--web-urls") {
            options.mode = .urlList(URL(fileURLWithPath: list))
        } else if let bundle = value(after: "--app") {
            options.mode = .app(bundleID: bundle)
        }

        if let out = value(after: "--out") {
            options.outputRoot = URL(fileURLWithPath: out, isDirectory: true)
        }
        if let text = value(after: "--viewports") {
            let parsed = CrawlPlan.parseViewports(text)
            if !parsed.isEmpty { viewports = parsed }
        }
        if let text = value(after: "--schemes") {
            let parsed = text.split(separator: ",").compactMap {
                PageTheme.Scheme(rawValue: String($0).trimmingCharacters(in: .whitespaces))
            }
            if !parsed.isEmpty { schemes = parsed }
        }
        if let text = value(after: "--zooms") {
            let parsed = text.split(separator: ",").compactMap { Double($0) }
            if !parsed.isEmpty { zooms = parsed }
        }
        if let text = value(after: "--scrolls"), let parsed = Int(text) { scrolls = parsed }
        if let text = value(after: "--seed"), let parsed = UInt64(text) { options.seed = parsed }
        if let text = value(after: "--interval"), let parsed = Double(text) { options.interval = parsed }

        options.plan = CrawlPlan(
            viewports: viewports, schemes: schemes, zooms: zooms, scrollSteps: scrolls)
        var canny = CannyOptions.standard
        if let low = value(after: "--canny-low").flatMap(Double.init) { canny.lowThreshold = low }
        if let high = value(after: "--canny-high").flatMap(Double.init) { canny.highThreshold = high }
        if let blur = value(after: "--canny-blur").flatMap(Int.init) { canny.blurKernel = blur }
        if let close = value(after: "--canny-close").flatMap(Int.init) { canny.closeKernel = close }
        if let size = value(after: "--min-size").flatMap(Int.init) {
            canny.minWidth = size
            canny.minHeight = size
        }
        options.canny = canny
        options.offscreen = arguments.contains("--offscreen")
        options.quitWhenDone = arguments.contains("--quit-when-done")
        options.record = arguments.contains("--record")
        return options
    }

    static let usage = """
    VisionAX Harvest — builds the classifier's training data.

      --web-synthetic <n>     generate and crawl n synthetic pages
      --web-urls <file>       crawl every URL in a file (one per line, # comments)
      --app <bundle-id>       harvest a running app's AX tree against a screen capture
      --record --interval <s> with --app: keep sampling every s seconds
      --out <dir>             dataset root (default: Dataset)
      --viewports 1280x800,1440x900
      --schemes light,dark
      --zooms 1.0,1.25
      --scrolls <n>           screens down to sample per page
      --seed <n>              synthetic generator seed
      --canny-low <n>         detector thresholds for this run (default 50 / 150)
      --canny-high <n>
      --canny-blur <n>        gaussian kernel before Canny, 0 = none
      --canny-close <n>       morphological close after Canny, 0 = none
      --min-size <n>          smallest box side to keep
      --offscreen             hide the crawl window (timers throttle; use with care)
      --quit-when-done        exit when the run finishes
    """
}
