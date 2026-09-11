//
//  WebCrawler.swift
//  VisionAXWeb
//
//  WHAT: Renders a page in a real WKWebView and returns pixels + ground truth.
//  IN:   a URL or an HTML string, plus one CrawlPlan.Shot
//  OUT:  (CGImage, DOMPayload) for HarvestSession
//  PIN:  ON SCREEN BY DEFAULT — but only just. An invisible window has its timers
//        throttled and its rAF frozen, which is why this was written to show one.
//        MEASURED SINCE, on a synthetic page and on wikipedia / MDN / HN: offscreen
//        produced identical element counts and identical pixels everywhere except MDN,
//        where a late-arriving image left the offscreen render ~4% different. So
//        offscreen is safe for a single capture somebody is watching (the bench uses
//        it, and a browser window popping up would be worse), and the visible default
//        stays for unattended bulk crawls, where that 4% would go unnoticed forever.
//        The measured pixel scale is checked against the page's own devicePixelRatio
//        and the sample is DISCARDED when they disagree: a rect scaled by the wrong
//        factor lands nowhere near its pixels, and nothing downstream could tell.
//

import AppKit
import CoreGraphics
import Foundation
import WebKit

public enum WebCrawlerError: Error, CustomStringConvertible {
    case navigationFailed(String)
    case timedOut(String)
    case scriptFailed(String)
    case snapshotFailed
    case scaleDisagrees(measured: Double, reported: Double)

    public var description: String {
        switch self {
        case .navigationFailed(let reason): return "the page did not load: \(reason)"
        case .timedOut(let what): return "timed out waiting for \(what)"
        case .scriptFailed(let reason): return "harvest.js failed: \(reason)"
        case .snapshotFailed: return "the web view returned no snapshot"
        case .scaleDisagrees(let measured, let reported):
            return "measured pixel scale \(measured) but the page reports \(reported)"
        }
    }
}

@MainActor
public final class WebCrawler: NSObject, WKNavigationDelegate {
    public struct Capture: Sendable {
        public var image: CGImage
        public var payload: DOMPayload
        public var scale: Double
    }

    private let window: NSWindow
    private let webView: WKWebView
    private let script: String
    private var pending: CheckedContinuation<Void, Error>?
    private let offscreen: Bool

    public init(offscreen: Bool = false) throws {
        self.offscreen = offscreen
        self.script = try Self.loadScript()

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        // No persistent store: a second run must not see the first run's cookies, or
        // a logged-in banner appears in one sample and not the next for no reason.
        configuration.websiteDataStore = .nonPersistent()

        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        window = NSWindow(
            contentRect: CGRect(x: 80, y: 80, width: 1280, height: 800),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "VisionAX — loading"
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        if !offscreen {
            window.orderFrontRegardless()
        }
    }

    deinit {
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    private static func loadScript() throws -> String {
        do {
            return try WebResources.harvestScript()
        } catch {
            throw WebCrawlerError.scriptFailed("harvest.js is not in the resource bundle")
        }
    }

    // MARK: - Crawling

    /// One shot of one page. `html` is used when given, otherwise `url` is loaded.
    public func capture(
        url: URL?,
        html: String?,
        shot: CrawlPlan.Shot,
        loadTimeout: Duration = .seconds(20)
    ) async throws -> Capture {
        resize(to: shot.viewport)
        webView.appearance = NSAppearance(named: shot.scheme == .dark ? .darkAqua : .aqua)
        webView.pageZoom = shot.zoom

        try await load(url: url, html: html, timeout: loadTimeout)
        try await settle()

        if shot.scrollIndex > 0 {
            let offset = Double(shot.scrollIndex) * Double(shot.viewport.height)
            _ = try? await evaluate("window.scrollTo(0, \(offset)); 1")
            try await Task.sleep(for: .milliseconds(180))
        }

        _ = try await evaluate(script + "\n1")
        let raw = try await evaluate("window.__vxHarvest({})")
        guard let json = raw as? String else {
            throw WebCrawlerError.scriptFailed("the walker returned \(type(of: raw))")
        }
        let payload = try AXTreeJSONDecoderShim.decode(DOMPayload.self, from: json)

        let image = try await snapshot()
        let measured = Double(image.width) / Double(shot.viewport.width)
        guard abs(measured - payload.dpr) < 0.01 else {
            throw WebCrawlerError.scaleDisagrees(measured: measured, reported: payload.dpr)
        }
        return Capture(image: image, payload: payload, scale: measured)
    }

    private func resize(to viewport: CGSize) {
        let frame = CGRect(origin: .zero, size: viewport)
        webView.frame = frame
        window.setContentSize(viewport)
        webView.layoutSubtreeIfNeeded()
    }

    private func load(url: URL?, html: String?, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.pending = continuation
                    if let html {
                        self.webView.loadHTMLString(html, baseURL: nil)
                    } else if let url {
                        self.webView.load(URLRequest(url: url))
                    } else {
                        self.pending = nil
                        continuation.resume(throwing: WebCrawlerError.navigationFailed("nothing to load"))
                    }
                }
            }
            group.addTask { @MainActor in
                try await Task.sleep(for: timeout)
                throw WebCrawlerError.timedOut("the page to load")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Fonts and images decided, then a beat for the layout they caused.
    private func settle() async throws {
        _ = try? await evaluate("""
            (async () => {
              try { await document.fonts.ready; } catch (e) {}
              const images = Array.from(document.images).slice(0, 60);
              await Promise.all(images.map(i => i.decode ? i.decode().catch(() => {}) : null));
              return 1;
            })()
            """)
        try await Task.sleep(for: .milliseconds(300))
    }

    private func evaluate(_ javaScript: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javaScript) { value, error in
                if let error {
                    continuation.resume(throwing: WebCrawlerError.scriptFailed(
                        error.localizedDescription))
                } else {
                    continuation.resume(returning: value ?? 0)
                }
            }
        }
    }

    private func snapshot() async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: WebCrawlerError.scriptFailed(
                        error.localizedDescription))
                    return
                }
                guard let image,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else {
                    continuation.resume(throwing: WebCrawlerError.snapshotFailed)
                    return
                }
                continuation.resume(returning: cgImage)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pending?.resume()
        pending = nil
    }

    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        pending?.resume(throwing: WebCrawlerError.navigationFailed(error.localizedDescription))
        pending = nil
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        pending?.resume(throwing: WebCrawlerError.navigationFailed(error.localizedDescription))
        pending = nil
    }
}

/// The house decoder, reachable from this module without exporting it from VisionAX.
enum AXTreeJSONDecoderShim {
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }
}
