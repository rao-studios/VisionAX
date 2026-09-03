//
//  SyntheticPageGenerator.swift
//  VisionAXWeb
//
//  WHAT: One seed → one complete, self-contained HTML page.
//  IN:   SeededRandom, PageTheme, Components
//  OUT:  WebCrawler (loadHTMLString — no network, no assets)
//  PIN:  SELF-CONTAINED IS A HARD REQUIREMENT, not a convenience. Every image is an
//        inline SVG and every style is in one <style> block, so a page renders
//        identically on a machine with no network and cannot change under us between
//        two harvests. A page that fetched a font would produce a different screenshot
//        on a cold cache, and the boxes would move for reasons no seed records.
//

import Foundation

public struct SyntheticPage: Equatable, Sendable {
    public let seed: UInt64
    public let title: String
    public let html: String
    public let theme: PageTheme

    /// The identity a dataset sample carries — the page is fully recoverable from it.
    public var origin: String { "synthetic://page/\(seed)" }
}

public enum SyntheticPageGenerator {
    /// Every block kind. Named so a test can assert the generator reaches all of them.
    public enum Block: String, CaseIterable, Sendable {
        case navBar, form, buttonGroup, card, table, list, tabs, toolbar
        case scroller, disclosure, dialog, prose
        // THE SHAPES THE WEB IS ACTUALLY MADE OF, and the corpus was not: a page of
        // results, a grid of videos, a bar of wordless icons, a player, an open menu,
        // page numbers, a consent wall, a search page. Every one of them is a case the
        // browsing lane has to answer and the model had never seen.
        case searchResults, mediaGrid, iconBar, player, menu, pagination, overlay, searchHero
    }

    public static func page(seed: UInt64) -> SyntheticPage {
        var generator = SeededRandom(seed: seed)
        let theme = PageTheme.random(using: &generator)
        let title = Components.title(using: &generator)

        var blocks: [Block] = []
        // A nav bar on most pages: it is where toolbars, tabs and search fields live on
        // the real web, and a page that never has one is a page unlike any real one.
        if generator.bool(chance: 0.8) { blocks.append(.navBar) }
        // AN OVERLAY COVERS THE PAGE IT IS ON, and everything under it stops being
        // visible ground truth. It has to be in the corpus — a consent wall is what
        // stands between a browsing turn and the page it was asked about — but on one
        // page in twelve, not on a quarter of them, or the corpus is mostly dimmed
        // backdrops. A menu is the same shape of problem, smaller.
        let covering: Set<Block> = [.overlay, .menu]
        let body = Block.allCases.filter { $0 != .navBar && !covering.contains($0) }
        blocks.append(contentsOf: generator.sample(body, count: generator.int(in: 3...7)))
        if generator.bool(chance: 0.12) { blocks.append(.menu) }
        if generator.bool(chance: 0.08) { blocks.append(.overlay) }

        let sidebar = generator.bool(chance: 0.35)
        let rendered = blocks.map { render($0, using: &generator) }.joined(separator: "\n")

        let content: String
        if sidebar {
            let links = (0..<generator.int(in: 4...7))
                .map { _ in "<li><a href=\"/\(Components.nouns.first ?? "x")\">\(Components.title(using: &generator))</a></li>" }
                .joined(separator: "\n      ")
            content = """
            <div class="row" style="align-items: flex-start;">
              <aside class="sidebar">
                <h3>\(Components.title(using: &generator))</h3>
                <ul class="list">
                  \(links)
                </ul>
              </aside>
              <main style="flex: 1; min-width: 0;">
            \(rendered)
              </main>
            </div>
            """
        } else {
            content = "<main>\n\(rendered)\n</main>"
        }

        let html = """
        <!DOCTYPE html>
        <html lang="en" data-seed="\(seed)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        \(theme.css)
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        \(content)
        </body>
        </html>
        """

        return SyntheticPage(seed: seed, title: title, html: html, theme: theme)
    }

    private static func render(_ block: Block, using generator: inout SeededRandom) -> String {
        switch block {
        case .navBar: return Components.navBar(using: &generator)
        case .form: return Components.form(using: &generator)
        case .buttonGroup: return Components.buttonGroup(using: &generator)
        case .card: return Components.card(using: &generator)
        case .table: return Components.table(using: &generator)
        case .list: return Components.list(using: &generator)
        case .tabs: return Components.tabs(using: &generator)
        case .toolbar: return Components.toolbar(using: &generator)
        case .scroller: return Components.scroller(using: &generator)
        case .disclosure: return Components.disclosure(using: &generator)
        case .dialog: return Components.dialog(using: &generator)
        case .prose: return Components.prose(using: &generator)
        case .searchResults: return Components.searchResults(using: &generator)
        case .mediaGrid: return Components.mediaGrid(using: &generator)
        case .iconBar: return Components.iconBar(using: &generator)
        case .player: return Components.player(using: &generator)
        case .menu: return Components.menu(using: &generator)
        case .pagination: return Components.pagination(using: &generator)
        case .overlay: return Components.overlay(using: &generator)
        case .searchHero: return Components.searchHero(using: &generator)
        }
    }
}
