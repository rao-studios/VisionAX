//
//  WebResources.swift
//  VisionAXWeb
//
//  WHAT: This module's own resource bundle, under a name that cannot be mistaken.
//  IN:   WebCrawler, HarvestJSTests
//  OUT:  harvest.js, Seeds/urls.txt
//  PIN:  `Bundle.module` is generated once per target, so a file that imports both
//        VisionAX and VisionAXHarvestKit sees two of them and the reference stops
//        compiling. Naming this module's bundle here settles it, and gives the two
//        shipped resources one accessor apiece instead of string literals at call sites.
//

import Foundation

public enum WebResources {
    public static var bundle: Bundle { .module }

    /// The DOM walker injected into every crawled page.
    public static func harvestScript() throws -> String {
        guard let url = bundle.url(forResource: "harvest", withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The default real-page corpus, shipped so `--web-urls` works with no arguments.
    public static var defaultURLList: URL? {
        bundle.url(forResource: "urls", withExtension: "txt", subdirectory: "Seeds")
    }
}
