//
//  Components.swift
//  VisionAXWeb
//
//  WHAT: The building blocks a synthetic page is assembled from.
//  IN:   SyntheticPageGenerator + SeededRandom
//  OUT:  HTML fragments
//  PIN:  EVERY CONTROL TYPE MUST APPEAR SOMEWHERE HERE, because a class the generator
//        cannot produce is a class the model will only ever see in the handful of real
//        pages that happen to contain one — and rare classes are exactly the ones that
//        collapse into the majority. The corpus generator is the class-balance lever;
//        the real-URL list is the realism lever. These blocks are also deliberately
//        WORDY: text runs are the commonest thing on any screen, and a page with three
//        words on it would teach the model the wrong prior about AXStaticText.
//

import Foundation

enum Components {
    // Vocabulary for filling pages with plausible words rather than lorem ipsum,
    // which has an unusual letter distribution and unusual word lengths.
    static let nouns = ["account", "project", "invoice", "message", "report", "setting",
                        "profile", "workspace", "document", "dashboard", "member", "task"]
    static let verbs = ["Create", "Delete", "Update", "Archive", "Publish", "Review",
                        "Export", "Import", "Share", "Duplicate", "Rename", "Send"]
    static let adjectives = ["recent", "shared", "archived", "pending", "active",
                             "draft", "starred", "hidden"]

    static func sentence(using generator: inout SeededRandom, words: Int = 12) -> String {
        var parts: [String] = []
        for index in 0..<words {
            if index % 4 == 0 {
                parts.append(generator.pick(adjectives))
            } else if index % 3 == 0 {
                parts.append(generator.pick(verbs).lowercased())
            } else {
                parts.append(generator.pick(nouns))
            }
        }
        return parts.joined(separator: " ").capitalizedFirst + "."
    }

    static func title(using generator: inout SeededRandom) -> String {
        "\(generator.pick(verbs)) \(generator.pick(nouns))"
    }

    // MARK: - Blocks

    static func navBar(using generator: inout SeededRandom) -> String {
        let links = generator.sample(nouns, count: generator.int(in: 3...5))
            .map { "<a href=\"/\($0)\">\($0.capitalizedFirst)</a>" }
            .joined(separator: "\n    ")
        let search = generator.bool(chance: 0.6)
            ? "<input type=\"search\" placeholder=\"Search\" aria-label=\"Search\">"
            : ""
        return """
        <nav class="bar" role="navigation">
          <strong>\(title(using: &generator))</strong>
          \(links)
          \(search)
          <button type="button">\(generator.pick(verbs))</button>
        </nav>
        """
    }

    static func form(using generator: inout SeededRandom) -> String {
        // Every text-like input type, so none of them is a rare class.
        let textTypes = ["text", "email", "password", "search", "tel", "url", "number"]
        var fields: [String] = []
        for type in generator.sample(textTypes, count: generator.int(in: 2...4)) {
            let name = generator.pick(nouns)
            fields.append("""
            <div>
              <label for="f-\(type)-\(name)">\(name.capitalizedFirst)</label>
              <input type="\(type)" id="f-\(type)-\(name)" name="\(name)" placeholder="\(name)">
            </div>
            """)
        }
        fields.append("""
        <div>
          <label for="ta-\(generator.int(in: 1...999))">Notes</label>
          <textarea placeholder="\(sentence(using: &generator, words: 6))"></textarea>
        </div>
        """)
        let choiceName = generator.pick(nouns)
        fields.append("""
        <fieldset>
          <label><input type="checkbox" checked> \(generator.pick(adjectives).capitalizedFirst)</label>
          <label><input type="checkbox"> \(generator.pick(adjectives).capitalizedFirst)</label>
          <label><input type="radio" name="r-\(choiceName)" checked> \(generator.pick(nouns).capitalizedFirst)</label>
          <label><input type="radio" name="r-\(choiceName)"> \(generator.pick(nouns).capitalizedFirst)</label>
        </fieldset>
        """)
        fields.append("""
        <div>
          <label for="s-\(choiceName)">\(choiceName.capitalizedFirst)</label>
          <select id="s-\(choiceName)">
            <option>\(generator.pick(nouns).capitalizedFirst)</option>
            <option>\(generator.pick(nouns).capitalizedFirst)</option>
          </select>
        </div>
        """)
        fields.append("""
        <div>
          <label for="rg-\(choiceName)">Volume</label>
          <input type="range" id="rg-\(choiceName)" min="0" max="100" value="\(generator.int(in: 10...90))">
        </div>
        """)
        return """
        <form class="card">
          <h3>\(title(using: &generator))</h3>
          <div class="col">
            \(fields.joined(separator: "\n    "))
            <div class="row">
              <button type="submit">Save</button>
              <button type="button">Cancel</button>
              <a href="/help">Need help?</a>
            </div>
          </div>
        </form>
        """
    }

    static func buttonGroup(using generator: inout SeededRandom) -> String {
        let buttons = (0..<generator.int(in: 2...5))
            .map { _ in "<button type=\"button\">\(generator.pick(verbs))</button>" }
            .joined(separator: "\n  ")
        return """
        <div class="card">
          <h3>\(title(using: &generator))</h3>
          <p>\(sentence(using: &generator))</p>
          <div class="row">
          \(buttons)
          </div>
        </div>
        """
    }

    /// Inline SVG rather than a linked file: the crawler must work offline, and a
    /// broken <img> is a box with no pixels, which teaches the model nothing.
    static func card(using generator: inout SeededRandom) -> String {
        let width = generator.int(in: 60...160)
        let height = generator.int(in: 40...120)
        let hue = generator.int(in: 0...359)
        return """
        <div class="card">
          <div class="row">
            <svg width="\(width)" height="\(height)" role="img" aria-label="\(generator.pick(nouns))">
              <rect width="\(width)" height="\(height)" fill="hsl(\(hue), 60%, 55%)"></rect>
              <circle cx="\(width / 2)" cy="\(height / 2)" r="\(min(width, height) / 4)" fill="hsl(\((hue + 40) % 360), 70%, 75%)"></circle>
            </svg>
            <div class="col">
              <h3>\(title(using: &generator))</h3>
              <p class="muted">\(sentence(using: &generator, words: 10))</p>
              <a href="/\(generator.pick(nouns))">Read more</a>
            </div>
          </div>
        </div>
        """
    }

    // MARK: - The shapes the corpus was missing

    /// A page of search results: a link, an address line, a snippet, repeated.
    ///
    /// PIN: THE TITLE IS AN ANCHOR AROUND A HEADING WITH NO BORDER, which is exactly the
    /// shape the edge detector cannot see and the reason real pages scored 33% recall.
    /// It is here so the head is trained on the box the text lane contributes.
    static func searchResults(using generator: inout SeededRandom) -> String {
        var rows: [String] = []
        for index in 0..<generator.int(in: 5...9) {
            let promoted = index == 0 && generator.bool(chance: 0.3)
            let marker = promoted ? "<span class=\"muted\">Sponsored</span>" : ""
            rows.append("""
            <li>
              \(marker)
              <a href="/\(generator.pick(nouns))"><h3>\(sentence(using: &generator, words: generator.int(in: 4...8)))</h3></a>
              <div class="muted">\(generator.pick(nouns)).example \u{203A} \(generator.pick(nouns))</div>
              <p>\(sentence(using: &generator, words: generator.int(in: 12...22)))</p>
            </li>
            """)
        }
        return """
        <section role="region" aria-label="Results">
          <ul class="list">
            \(rows.joined(separator: "\n    "))
          </ul>
        </section>
        """
    }

    /// A grid of picture-and-title cards with a duration badge — the shape a person
    /// means by "the first video".
    static func mediaGrid(using generator: inout SeededRandom) -> String {
        var cards: [String] = []
        for _ in 0..<generator.int(in: 6...12) {
            let hue = generator.int(in: 0...359)
            let minutes = generator.int(in: 1...59)
            let seconds = generator.int(in: 0...59)
            cards.append("""
            <li class="card" style="width: 220px;">
              <a href="/\(generator.pick(nouns))">
                <svg width="200" height="112" role="img" aria-label="\(generator.pick(nouns))">
                  <rect width="200" height="112" fill="hsl(\(hue), 55%, 45%)"></rect>
                </svg>
                <h3>\(sentence(using: &generator, words: generator.int(in: 3...7)))</h3>
              </a>
              <div class="muted">\(generator.pick(nouns).capitalizedFirst) \u{00B7} \(minutes):\(seconds < 10 ? "0" : "")\(seconds)</div>
            </li>
            """)
        }
        return """
        <ul class="list" style="display: flex; flex-wrap: wrap; gap: 16px; list-style: none; padding: 0;">
          \(cards.joined(separator: "\n  "))
        </ul>
        """
    }

    /// A row of icon-only buttons. Every one of them is a box with no words in it, which
    /// is the case the label ladder's icon rung exists for.
    static func iconBar(using generator: inout SeededRandom) -> String {
        let glyphs: [(String, String)] = [
            ("Search", "<circle cx=\"9\" cy=\"9\" r=\"6\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"/><line x1=\"13\" y1=\"13\" x2=\"19\" y2=\"19\" stroke=\"currentColor\" stroke-width=\"2\"/>"),
            ("Close", "<line x1=\"5\" y1=\"5\" x2=\"19\" y2=\"19\" stroke=\"currentColor\" stroke-width=\"2\"/><line x1=\"19\" y1=\"5\" x2=\"5\" y2=\"19\" stroke=\"currentColor\" stroke-width=\"2\"/>"),
            ("Menu", "<line x1=\"4\" y1=\"7\" x2=\"20\" y2=\"7\" stroke=\"currentColor\" stroke-width=\"2\"/><line x1=\"4\" y1=\"12\" x2=\"20\" y2=\"12\" stroke=\"currentColor\" stroke-width=\"2\"/><line x1=\"4\" y1=\"17\" x2=\"20\" y2=\"17\" stroke=\"currentColor\" stroke-width=\"2\"/>"),
            ("More", "<circle cx=\"12\" cy=\"5\" r=\"2\" fill=\"currentColor\"/><circle cx=\"12\" cy=\"12\" r=\"2\" fill=\"currentColor\"/><circle cx=\"12\" cy=\"19\" r=\"2\" fill=\"currentColor\"/>"),
            ("Back", "<polyline points=\"14,5 7,12 14,19\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"/>"),
            ("Add", "<line x1=\"12\" y1=\"5\" x2=\"12\" y2=\"19\" stroke=\"currentColor\" stroke-width=\"2\"/><line x1=\"5\" y1=\"12\" x2=\"19\" y2=\"12\" stroke=\"currentColor\" stroke-width=\"2\"/>"),
            ("Settings", "<circle cx=\"12\" cy=\"12\" r=\"4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"/><circle cx=\"12\" cy=\"12\" r=\"8\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1\"/>"),
        ]
        let chosen = generator.sample(glyphs.map(\.0), count: generator.int(in: 4...7))
        let buttons = chosen.map { name -> String in
            let art = glyphs.first { $0.0 == name }?.1 ?? ""
            return """
            <button type="button" aria-label="\(name)" style="width: 36px; height: 36px; padding: 0;">
              <svg width="24" height="24" viewBox="0 0 24 24">\(art)</svg>
            </button>
            """
        }
        return """
        <div class="bar" role="toolbar" aria-label="Actions">
          \(buttons.joined(separator: "\n  "))
        </div>
        """
    }

    /// A video with a transport under it: a track, a clock, and small square controls.
    static func player(using generator: inout SeededRandom) -> String {
        let progress = generator.int(in: 5...90)
        let hue = generator.int(in: 190...260)
        return """
        <div class="card" style="background: #111; color: #eee; padding: 0;">
          <svg width="100%" height="220" role="img" aria-label="\(title(using: &generator))">
            <rect width="100%" height="220" fill="hsl(\(hue), 30%, 18%)"></rect>
          </svg>
          <div class="row" style="padding: 8px 12px; gap: 12px;">
            <button type="button" aria-label="Play" style="width: 32px; height: 32px; padding: 0;">
              <svg width="20" height="20" viewBox="0 0 20 20"><polygon points="5,3 17,10 5,17" fill="currentColor"/></svg>
            </button>
            <button type="button" aria-label="Volume" style="width: 32px; height: 32px; padding: 0;">
              <svg width="20" height="20" viewBox="0 0 20 20"><polygon points="3,7 7,7 11,3 11,17 7,13 3,13" fill="currentColor"/></svg>
            </button>
            <span class="muted">\(generator.int(in: 0...9)):\(generator.int(in: 10...59)) / \(generator.int(in: 10...59)):\(generator.int(in: 10...59))</span>
            <input type="range" aria-label="Seek" min="0" max="100" value="\(progress)" style="flex: 1;">
            <button type="button" aria-label="Full screen" style="width: 32px; height: 32px; padding: 0;">
              <svg width="20" height="20" viewBox="0 0 20 20"><rect x="3" y="3" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"/></svg>
            </button>
          </div>
        </div>
        """
    }

    /// A dropdown, open — a stack of same-width rows over the page.
    static func menu(using generator: inout SeededRandom) -> String {
        let items = (0..<generator.int(in: 4...8))
            .map { _ in "<li role=\"menuitem\"><a href=\"/\(generator.pick(nouns))\">\(title(using: &generator))</a></li>" }
            .joined(separator: "\n    ")
        return """
        <div style="position: relative;">
          <button type="button" aria-expanded="true" aria-haspopup="true">\(generator.pick(verbs).capitalizedFirst)</button>
          <ul class="card" role="menu" style="position: absolute; z-index: 5; min-width: 180px; list-style: none;">
            \(items)
          </ul>
        </div>
        """
    }

    /// Page numbers — small identical boxes in a row, one of them current.
    static func pagination(using generator: inout SeededRandom) -> String {
        let pages = generator.int(in: 5...9)
        let current = generator.int(in: 1...pages)
        let links = (1...pages).map { number -> String in
            number == current
                ? "<a href=\"/page/\(number)\" aria-current=\"page\"><strong>\(number)</strong></a>"
                : "<a href=\"/page/\(number)\">\(number)</a>"
        }
        return """
        <nav class="bar" aria-label="Pages">
          <a href="/page/\(max(1, current - 1))">Previous</a>
          \(links.joined(separator: "\n  "))
          <a href="/page/\(min(pages, current + 1))">Next</a>
        </nav>
        """
    }

    /// A dialog over a dimmed page — the shape of a consent wall, which is the thing
    /// standing between a browsing turn and the page it was asked about.
    static func overlay(using generator: inout SeededRandom) -> String {
        """
        <div style="position: fixed; inset: 0; background: rgba(0,0,0,0.45); z-index: 10;"></div>
        <div class="card" role="dialog" aria-modal="true" aria-label="\(title(using: &generator))"
             style="position: fixed; left: 20%; top: 25%; width: 60%; z-index: 11;">
          <h3>\(title(using: &generator))</h3>
          <p>\(sentence(using: &generator, words: generator.int(in: 14...26)))</p>
          <div class="row">
            <button type="button">Accept all</button>
            <button type="button">Reject all</button>
            <a href="/\(generator.pick(nouns))">Manage choices</a>
          </div>
        </div>
        """
    }

    /// One large centred field with a button or two under it.
    static func searchHero(using generator: inout SeededRandom) -> String {
        """
        <div class="card" style="text-align: center; padding: 48px 24px;">
          <h2>\(title(using: &generator))</h2>
          <input type="search" aria-label="Search" placeholder="Search \(generator.pick(nouns))"
                 style="width: 70%; max-width: 520px; height: 40px;">
          <div class="row" style="justify-content: center;">
            <button type="submit">Search</button>
            <button type="button">\(generator.pick(verbs).capitalizedFirst)</button>
          </div>
        </div>
        """
    }

    static func table(using generator: inout SeededRandom) -> String {
        let columns = generator.sample(nouns, count: generator.int(in: 3...4))
        let header = columns.map { "<th>\($0.capitalizedFirst)</th>" }.joined()
        var rows: [String] = []
        for _ in 0..<generator.int(in: 3...7) {
            let cells = columns.map { _ in "<td>\(generator.pick(adjectives).capitalizedFirst)</td>" }
                .joined()
            rows.append("<tr>\(cells)</tr>")
        }
        return """
        <div class="card">
          <h3>\(title(using: &generator))</h3>
          <table>
            <thead><tr>\(header)</tr></thead>
            <tbody>
            \(rows.joined(separator: "\n    "))
            </tbody>
          </table>
        </div>
        """
    }

    static func list(using generator: inout SeededRandom) -> String {
        let ordered = generator.bool()
        let tag = ordered ? "ol" : "ul"
        let items = (0..<generator.int(in: 3...6))
            .map { _ in "<li>\(sentence(using: &generator, words: 6))</li>" }
            .joined(separator: "\n    ")
        return """
        <div class="card">
          <h3>\(title(using: &generator))</h3>
          <\(tag) class="list">
            \(items)
          </\(tag)>
        </div>
        """
    }

    static func tabs(using generator: inout SeededRandom) -> String {
        let names = generator.sample(nouns, count: generator.int(in: 2...4))
        let items = names.enumerated().map { index, name in
            "<div class=\"tab\" role=\"tab\" aria-selected=\"\(index == 0)\">\(name.capitalizedFirst)</div>"
        }.joined(separator: "\n    ")
        return """
        <div class="card">
          <div class="tabs" role="tablist">
            \(items)
          </div>
          <p>\(sentence(using: &generator))</p>
        </div>
        """
    }

    static func toolbar(using generator: inout SeededRandom) -> String {
        let buttons = (0..<generator.int(in: 3...6))
            .map { _ in "<button type=\"button\">\(generator.pick(verbs).prefix(4))</button>" }
            .joined(separator: "\n  ")
        return """
        <div class="toolbar" role="toolbar">
        \(buttons)
        </div>
        """
    }

    static func scroller(using generator: inout SeededRandom) -> String {
        let lines = (0..<generator.int(in: 8...16))
            .map { _ in "<p>\(sentence(using: &generator, words: 14))</p>" }
            .joined(separator: "\n    ")
        return """
        <div class="card">
          <h3>\(title(using: &generator))</h3>
          <div class="scroller">
            \(lines)
          </div>
        </div>
        """
    }

    static func disclosure(using generator: inout SeededRandom) -> String {
        """
        <div class="card">
          <details open>
            <summary>\(title(using: &generator))</summary>
            <p>\(sentence(using: &generator))</p>
          </details>
          <details>
            <summary>\(title(using: &generator))</summary>
            <p>\(sentence(using: &generator))</p>
          </details>
        </div>
        """
    }

    static func dialog(using generator: inout SeededRandom) -> String {
        """
        <dialog class="shown" open role="dialog" aria-label="\(title(using: &generator))">
          <h3>\(title(using: &generator))</h3>
          <p>\(sentence(using: &generator, words: 10))</p>
          <div class="row">
            <button type="button">Confirm</button>
            <button type="button">Dismiss</button>
          </div>
        </dialog>
        """
    }

    static func prose(using generator: inout SeededRandom) -> String {
        let paragraphs = (0..<generator.int(in: 2...4))
            .map { _ in "<p>\(sentence(using: &generator, words: generator.int(in: 14...28)))</p>" }
            .joined(separator: "\n  ")
        return """
        <section>
          <h2>\(title(using: &generator))</h2>
          \(paragraphs)
        </section>
        """
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
