//
//  CrawlPlan.swift
//  VisionAXWeb
//
//  WHAT: The matrix of shots to take of one page.
//  IN:   HarvestLaunchOptions
//  OUT:  WebCrawler
//  PIN:  One page yields many samples, and that is the cheapest variety there is: the
//        same DOM at 1280 and 1920 is a genuinely different layout, and in dark mode
//        it is genuinely different EDGES — which is what Canny sees. Scroll positions
//        matter for a different reason: everything above the fold is a header, and a
//        model trained only on first screens learns that priors about position which
//        stop holding the moment anyone scrolls.
//

import CoreGraphics
import Foundation

public struct CrawlPlan: Sendable, Equatable {
    public var viewports: [CGSize]
    public var schemes: [PageTheme.Scheme]
    public var zooms: [Double]
    /// How many screens down to sample, including the top one.
    public var scrollSteps: Int

    public init(
        viewports: [CGSize] = [CGSize(width: 1280, height: 800)],
        schemes: [PageTheme.Scheme] = [.light],
        zooms: [Double] = [1.0],
        scrollSteps: Int = 1
    ) {
        self.viewports = viewports
        self.schemes = schemes
        self.zooms = zooms
        self.scrollSteps = max(1, scrollSteps)
    }

    public struct Shot: Sendable, Equatable {
        public var viewport: CGSize
        public var scheme: PageTheme.Scheme
        public var zoom: Double
        public var scrollIndex: Int

        public init(
            viewport: CGSize,
            scheme: PageTheme.Scheme = .light,
            zoom: Double = 1,
            scrollIndex: Int = 0
        ) {
            self.viewport = viewport
            self.scheme = scheme
            self.zoom = zoom
            self.scrollIndex = scrollIndex
        }
    }

    /// Every combination, in a stable order so a re-run reproduces the same ids.
    public var shots: [Shot] {
        var shots: [Shot] = []
        for viewport in viewports {
            for scheme in schemes {
                for zoom in zooms {
                    for scrollIndex in 0..<scrollSteps {
                        shots.append(Shot(
                            viewport: viewport, scheme: scheme,
                            zoom: zoom, scrollIndex: scrollIndex))
                    }
                }
            }
        }
        return shots
    }

    /// Parses `1280x800,1440x900`.
    public static func parseViewports(_ text: String) -> [CGSize] {
        text.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                  w > 200, h > 200 else { return nil }
            return CGSize(width: w, height: h)
        }
    }
}
