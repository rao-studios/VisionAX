//
//  HarvestModel.swift
//  VisionAXHarvest
//
//  WHAT: Drives a harvest run and publishes what it is doing.
//  IN:   HarvestLaunchOptions
//  OUT:  HarvestRootView, Dataset/
//  PIN:  ONE FAILED PAGE MUST NOT END A RUN. A crawl of 300 pages will meet a dead
//        URL, a page that never settles, and a snapshot whose scale disagrees with
//        the page's own devicePixelRatio. Each is counted, named in the log, and
//        stepped over — a harvest that aborts on the first bad page is a harvest
//        nobody can leave running.
//

import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import VisionAX
import VisionAXHarvestKit
import VisionAXWeb

@MainActor
@Observable
final class HarvestModel {
    struct LogLine: Identifiable {
        let id = UUID()
        var text: String
        var isProblem: Bool
    }

    private(set) var log: [LogLine] = []
    private(set) var isRunning = false
    private(set) var progress = ""
    private(set) var written = 0
    private(set) var skipped = 0
    private(set) var recall = RecallReport()
    private(set) var lastImage: CGImage?
    private(set) var permissions = PermissionsGate.current()

    let options = HarvestLaunchOptions.parse()
    private var session: HarvestSession?
    private var task: Task<Void, Never>?

    var datasetPath: String { options.outputRoot.path }

    // MARK: - Entry

    func startIfRequested() async {
        guard options.mode != .idle else {
            note(HarvestLaunchOptions.usage)
            return
        }
        await start()
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            switch options.mode {
            case .idle:
                note("Nothing to do — pass --web-synthetic, --web-urls or --app.")
            case .syntheticWeb(let count):
                try await crawlSynthetic(count: count)
            case .urlList(let file):
                try await crawlURLs(in: file)
            case .app(let bundleID):
                try await harvestApp(bundleID: bundleID)
            }
        } catch {
            note("run failed: \(error)", isProblem: true)
        }

        try? session?.finish()
        if let session {
            note("")
            note(session.recall.formattedTable())
        }
        note("wrote \(written) samples, skipped \(skipped), into \(datasetPath)")

        if options.quitWhenDone {
            // A beat so the last lines reach the log window and stdout before exit.
            try? await Task.sleep(for: .milliseconds(400))
            NSApplication.shared.terminate(nil)
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
    }

    // MARK: - Web

    private func crawlSynthetic(count: Int) async throws {
        let session = try makeSession(source: .web)
        let crawler = try WebCrawler(offscreen: options.offscreen)
        let shots = options.plan.shots

        for index in 0..<count {
            if Task.isCancelled { return }
            let seed = options.seed &+ UInt64(index)
            let page = SyntheticPageGenerator.page(seed: seed)
            for shot in shots {
                progress = "synthetic \(index + 1)/\(count) · \(Int(shot.viewport.width))w \(shot.scheme.rawValue)"
                await capture(
                    with: crawler, session: session, url: nil, html: page.html,
                    shot: shot,
                    id: HarvestSession.webID(
                        url: page.origin, viewport: shot.viewport,
                        scheme: shot.scheme.rawValue, zoom: shot.zoom,
                        scrollIndex: shot.scrollIndex, seed: seed),
                    origin: HarvestOrigin(url: page.origin, title: page.title, seed: seed))
            }
        }
    }

    private func crawlURLs(in file: URL) async throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let urls = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0) }
        guard !urls.isEmpty else {
            note("no URLs in \(file.lastPathComponent)", isProblem: true)
            return
        }

        let session = try makeSession(source: .web)
        let crawler = try WebCrawler(offscreen: options.offscreen)
        let shots = options.plan.shots

        for (index, url) in urls.enumerated() {
            if Task.isCancelled { return }
            for shot in shots {
                progress = "\(index + 1)/\(urls.count) · \(url.host() ?? url.absoluteString)"
                await capture(
                    with: crawler, session: session, url: url, html: nil, shot: shot,
                    id: HarvestSession.webID(
                        url: url.absoluteString, viewport: shot.viewport,
                        scheme: shot.scheme.rawValue, zoom: shot.zoom,
                        scrollIndex: shot.scrollIndex, seed: nil),
                    origin: HarvestOrigin(url: url.absoluteString, title: url.absoluteString))
            }
        }
    }

    private func capture(
        with crawler: WebCrawler,
        session: HarvestSession,
        url: URL?,
        html: String?,
        shot: CrawlPlan.Shot,
        id: String,
        origin: HarvestOrigin
    ) async {
        do {
            let capture = try await crawler.capture(url: url, html: html, shot: shot)
            let bounds = PixelRect(
                x: 0, y: 0, width: capture.image.width, height: capture.image.height)
            let truth = capture.payload.groundTruth(
                vocabulary: session.vocabulary, imageBounds: bounds)
            var resolved = origin
            if origin.title == origin.url || origin.title.isEmpty {
                resolved.title = capture.payload.title
            }

            // A CONSENT WALL IS NOT THE PAGE THAT WAS ASKED FOR. A crawl of real pages
            // collects a fair number of them — a dimmed backdrop with two buttons on it
            // — and each one enters the corpus as though it were the results page it is
            // covering. A page with almost nothing in it, or with no links at all, did
            // not render what it was fetched for.
            if url != nil, !meetsTheBar(capture.payload) {
                session.skip()
                skipped = session.skipped
                note("skipped \(id): the page did not render (\(capture.payload.stats.emitted) elements)")
                return
            }

            let sampleRecall = try session.record(
                id: id, image: capture.image, groundTruth: truth, origin: resolved,
                scheme: shot.scheme.rawValue,
                viewport: HarvestViewport(
                    width: Int(shot.viewport.width), height: Int(shot.viewport.height),
                    zoom: shot.zoom,
                    scrollY: shot.scrollIndex * Int(shot.viewport.height)),
                scale: capture.scale)

            lastImage = capture.image
            written = session.written
            recall = session.recall
            note("\(id)  \(truth.count) elements  "
                 + "recall \(percent(sampleRecall.overall.rate))  "
                 + "\(capture.image.width)×\(capture.image.height)")
        } catch {
            session.skip()
            skipped = session.skipped
            note("skipped \(id): \(error)", isProblem: true)
        }
    }

    /// Did this page render what it was fetched for?
    ///
    /// Deliberately crude: the two failures worth catching are a wall in front of the
    /// page and a page that never finished loading, and both look like a document with
    /// hardly anything in it.
    static let minimumRenderedElements = 40
    static let minimumRenderedLinks = 5

    private func meetsTheBar(_ payload: DOMPayload) -> Bool {
        guard payload.stats.emitted >= Self.minimumRenderedElements else { return false }
        let links = payload.elements.filter { $0.role == "AXLink" && $0.href != nil }
        return links.count >= Self.minimumRenderedLinks
    }

    // MARK: - App

    private func harvestApp(bundleID: String) async throws {
        permissions = PermissionsGate.request()
        guard permissions.isReady else {
            note("cannot harvest \(bundleID): \(permissions.missingDescription)", isProblem: true)
            return
        }
        let session = try makeSession(source: .app)
        let harvester = try AppHarvester(bundleID: bundleID)
        note("harvesting \(bundleID) — bring its window forward")

        repeat {
            if Task.isCancelled { return }
            do {
                let capture = try await harvester.capture()
                let sampleRecall = try session.record(
                    id: HarvestSession.appID(bundleID: bundleID),
                    image: capture.image,
                    groundTruth: capture.elements,
                    origin: HarvestOrigin(bundleID: bundleID, title: capture.windowTitle),
                    scale: capture.scale)
                lastImage = capture.image
                written = session.written
                recall = session.recall
                note("\(capture.windowTitle)  \(capture.elements.count) elements  "
                     + "walk \(capture.walkMilliseconds)ms  recall \(percent(sampleRecall.overall.rate))")
            } catch {
                session.skip()
                skipped = session.skipped
                note("skipped: \(error)", isProblem: true)
            }
            if options.record {
                try? await Task.sleep(for: .seconds(options.interval))
            }
        } while options.record && !Task.isCancelled
    }

    // MARK: - Plumbing

    private func makeSession(source: HarvestSource) throws -> HarvestSession {
        let created = try HarvestSession(
            datasetRoot: options.outputRoot, source: source, options: options.canny)
        session = created
        return created
    }

    private func percent(_ rate: Double) -> String {
        String(format: "%.0f%%", rate * 100)
    }

    private func note(_ text: String, isProblem: Bool = false) {
        log.append(LogLine(text: text, isProblem: isProblem))
        // Also to stdout, so an unattended run leaves a transcript in the terminal.
        print(text)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
