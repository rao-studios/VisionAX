//
//  PageTheme.swift
//  VisionAXWeb
//
//  WHAT: The CSS a generated page is dressed in — colours, type, spacing, borders.
//  IN:   SeededRandom
//  OUT:  SyntheticPageGenerator (a <style> block)
//  PIN:  THE THEME IS THE POINT, not decoration. A classifier trained on one visual
//        style learns that style, not the roles: it would decide a button is
//        "a blue rounded rectangle" and then miss every outlined, square, or ghost
//        button on the real web. Randomising borders, fills, radii and contrast is
//        what forces the model onto structure. Dark mode is included for the same
//        reason — Canny sees inverted edges there, not merely different colours.
//

import Foundation

public struct PageTheme: Equatable, Sendable {
    public enum Scheme: String, Sendable, CaseIterable {
        case light
        case dark
    }

    public var scheme: Scheme
    public var background: String
    public var surface: String
    public var text: String
    public var mutedText: String
    public var accent: String
    public var accentText: String
    public var border: String
    public var fontStack: String
    public var baseFontSize: Int
    public var radius: Int
    public var spacing: Int
    public var borderWidth: Int
    /// Filled buttons on some pages, outlined on others.
    public var buttonIsFilled: Bool
    /// Whether cards and groups carry a visible border, a shadow, or nothing.
    public var cardStyle: CardStyle

    public enum CardStyle: String, Sendable, CaseIterable {
        case bordered
        case shadowed
        case flat
    }

    public static func random(using generator: inout SeededRandom) -> PageTheme {
        let scheme: Scheme = generator.bool() ? .light : .dark
        let accents = ["#2563eb", "#7c3aed", "#059669", "#dc2626", "#ea580c", "#0891b2", "#c026d3"]
        let fonts = [
            "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
            "Georgia, 'Times New Roman', serif",
            "'SF Mono', Menlo, Consolas, monospace",
            "Verdana, Geneva, sans-serif",
            "'Trebuchet MS', Tahoma, sans-serif",
        ]

        let light = scheme == .light
        return PageTheme(
            scheme: scheme,
            background: light ? generator.pick(["#ffffff", "#f8fafc", "#f5f5f4"])
                              : generator.pick(["#0b0f19", "#111827", "#18181b"]),
            surface: light ? generator.pick(["#ffffff", "#f1f5f9"])
                           : generator.pick(["#1f2937", "#27272a"]),
            text: light ? "#111827" : "#f3f4f6",
            mutedText: light ? "#6b7280" : "#9ca3af",
            accent: generator.pick(accents),
            accentText: "#ffffff",
            border: light ? "#d1d5db" : "#374151",
            fontStack: generator.pick(fonts),
            baseFontSize: generator.int(in: 13...17),
            radius: generator.pick([0, 2, 4, 6, 10, 16]),
            spacing: generator.int(in: 8...20),
            borderWidth: generator.pick([1, 1, 1, 2]),
            buttonIsFilled: generator.bool(chance: 0.6),
            cardStyle: generator.pick(CardStyle.allCases))
    }

    /// The stylesheet. Class names are shared with Components.swift.
    public var css: String {
        let cardDecoration: String
        switch cardStyle {
        case .bordered: cardDecoration = "border: \(borderWidth)px solid \(border);"
        case .shadowed: cardDecoration = "box-shadow: 0 1px 3px rgba(0,0,0,0.25);"
        case .flat: cardDecoration = "border: none;"
        }
        let buttonDecoration = buttonIsFilled
            ? "background: \(accent); color: \(accentText); border: \(borderWidth)px solid \(accent);"
            : "background: transparent; color: \(accent); border: \(borderWidth)px solid \(accent);"

        return """
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: \(spacing * 2)px;
          background: \(background); color: \(text);
          font-family: \(fontStack); font-size: \(baseFontSize)px; line-height: 1.5;
        }
        h1 { font-size: \(baseFontSize + 14)px; margin: 0 0 \(spacing)px; }
        h2 { font-size: \(baseFontSize + 8)px; margin: \(spacing * 2)px 0 \(spacing)px; }
        h3 { font-size: \(baseFontSize + 4)px; margin: \(spacing)px 0; }
        p { margin: 0 0 \(spacing)px; color: \(text); }
        a { color: \(accent); }
        .muted { color: \(mutedText); }
        .card {
          background: \(surface); border-radius: \(radius)px; padding: \(spacing + 4)px;
          margin-bottom: \(spacing)px; \(cardDecoration)
        }
        .row { display: flex; gap: \(spacing)px; align-items: center; flex-wrap: wrap; }
        .col { display: flex; flex-direction: column; gap: \(spacing)px; }
        button, .btn {
          padding: \(max(6, spacing - 2))px \(spacing + 6)px;
          border-radius: \(radius)px; font: inherit; cursor: pointer; \(buttonDecoration)
        }
        input[type=text], input[type=email], input[type=password], input[type=search],
        input[type=number], input[type=tel], input[type=url], textarea, select {
          padding: \(max(5, spacing - 4))px \(max(6, spacing - 2))px;
          border: \(borderWidth)px solid \(border); border-radius: \(radius)px;
          background: \(surface); color: \(text); font: inherit;
        }
        textarea { min-height: \(spacing * 5)px; width: 100%; }
        label { display: block; margin-bottom: 4px; color: \(mutedText); font-size: \(baseFontSize - 1)px; }
        nav.bar {
          display: flex; gap: \(spacing + 4)px; align-items: center;
          padding: \(spacing)px \(spacing + 4)px; background: \(surface);
          border-bottom: \(borderWidth)px solid \(border); margin-bottom: \(spacing * 2)px;
          border-radius: \(radius)px;
        }
        table { border-collapse: collapse; width: 100%; }
        th, td {
          border: \(borderWidth)px solid \(border);
          padding: \(max(4, spacing - 6))px \(spacing - 2)px; text-align: left;
        }
        th { background: \(surface); }
        ul.list, ol.list { padding-left: \(spacing + 10)px; }
        .tabs { display: flex; gap: 4px; border-bottom: \(borderWidth)px solid \(border); }
        .tab {
          padding: \(max(5, spacing - 4))px \(spacing + 2)px; cursor: pointer;
          border: \(borderWidth)px solid \(border); border-bottom: none;
          border-radius: \(radius)px \(radius)px 0 0; background: \(surface);
        }
        .tab[aria-selected=true] { background: \(accent); color: \(accentText); }
        .sidebar {
          width: 220px; background: \(surface); padding: \(spacing)px;
          border-right: \(borderWidth)px solid \(border); border-radius: \(radius)px;
        }
        .scroller { max-height: 180px; overflow-y: auto; border: \(borderWidth)px solid \(border);
          border-radius: \(radius)px; padding: \(spacing)px; }
        .toolbar { display: flex; gap: 6px; padding: 6px; background: \(surface);
          border: \(borderWidth)px solid \(border); border-radius: \(radius)px; }
        dialog.shown {
          display: block; position: static; margin: \(spacing)px 0;
          background: \(surface); color: \(text);
          border: \(borderWidth)px solid \(border); border-radius: \(radius)px;
          padding: \(spacing + 6)px; width: 60%;
        }
        """
    }
}
