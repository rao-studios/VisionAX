//
//  HarvestJSTests.swift
//  VisionAXHarvestKitTests
//
//  WHAT: harvest.js against a real WebKit layout, one assertion per mapping rule.
//  PIN:  A REAL WKWebView, not a parser. Every rule the walker applies — clipping,
//        occlusion, text-run rects, "does this div paint a box" — is a question only a
//        layout engine can answer, and a fixture-string test would pass while the real
//        walk returned nonsense. No window and no snapshot here: this is about the DOM
//        walk alone, which keeps the test independent of whether pixels can be drawn.
//

import Foundation
import Testing
import WebKit
@testable import VisionAX
@testable import VisionAXHarvestKit
@testable import VisionAXWeb

@MainActor
@Suite struct HarvestJSTests {

    // MARK: - Harness

    final class Loader: NSObject, WKNavigationDelegate {
        var pending: CheckedContinuation<Void, Error>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pending?.resume(); pending = nil
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            pending?.resume(throwing: error); pending = nil
        }
    }

    private static func script() throws -> String {
        try WebResources.harvestScript()
    }

    /// Lays out `body` at 1000×700 and returns what the walker saw.
    private func walk(_ body: String, style: String = "") async throws -> DOMPayload {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let loader = Loader()
        webView.navigationDelegate = loader

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        body { margin: 0; padding: 0; font: 16px -apple-system, sans-serif; }
        \(style)
        </style></head><body>\(body)</body></html>
        """

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loader.pending = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        _ = try await webView.evaluateJavaScript(try Self.script() + "\n1")
        let raw = try await webView.evaluateJavaScript("window.__vxHarvest({})")
        let json = try #require(raw as? String)
        return try AXTreeJSON.decode(DOMPayload.self, from: json)
    }

    private func roles(_ payload: DOMPayload, tag: String) -> [String] {
        payload.elements.filter { $0.tag == tag }.map(\.role)
    }

    // MARK: - The role table

    @Test func everyControlMapsToItsAXRole() async throws {
        let payload = try await walk("""
        <button>Press</button>
        <a href="/x">Link</a>
        <input type="text" value="t">
        <input type="password" value="p">
        <input type="search" value="s">
        <textarea>notes</textarea>
        <input type="checkbox" checked>
        <input type="radio" checked>
        <select><option>One</option></select>
        <input type="range" min="0" max="10" value="5">
        <h2>Heading</h2>
        <ul><li>Item</li></ul>
        <table><tr><td>Cell</td></tr></table>
        <div role="toolbar"><button>T</button></div>
        <svg width="40" height="40"><rect width="40" height="40" fill="red"></rect></svg>
        """)

        #expect(roles(payload, tag: "button").contains("AXButton"))
        #expect(roles(payload, tag: "a") == ["AXLink"])
        #expect(roles(payload, tag: "textarea") == ["AXTextArea"])
        #expect(roles(payload, tag: "select") == ["AXPopUpButton"])
        #expect(roles(payload, tag: "h2") == ["AXHeading"])
        #expect(roles(payload, tag: "ul") == ["AXList"])
        #expect(roles(payload, tag: "table") == ["AXTable"])
        #expect(roles(payload, tag: "tr") == ["AXRow"])
        #expect(roles(payload, tag: "td") == ["AXCell"])
        #expect(roles(payload, tag: "svg") == ["AXImage"])

        let inputs = payload.elements.filter { $0.tag == "input" }
        #expect(inputs.first { $0.inputType == "text" }?.role == "AXTextField")
        #expect(inputs.first { $0.inputType == "password" }?.role == "AXTextField")
        #expect(inputs.first { $0.inputType == "password" }?.subrole == "AXSecureTextField")
        #expect(inputs.first { $0.inputType == "search" }?.subrole == "AXSearchField")
        #expect(inputs.first { $0.inputType == "checkbox" }?.role == "AXCheckBox")
        #expect(inputs.first { $0.inputType == "radio" }?.role == "AXRadioButton")
        #expect(inputs.first { $0.inputType == "range" }?.role == "AXSlider")
        #expect(payload.elements.contains { $0.ariaRole == "toolbar" && $0.role == "AXToolbar" })
    }

    @Test func ariaTabIsARadioButtonWithATabSubrole() async throws {
        // What WebKit and Chromium both actually report. AXTab is the native NSTabView
        // role and never appears in web content.
        let payload = try await walk("""
        <div role="tablist"><div role="tab" aria-selected="true">One</div></div>
        """)
        let tab = try #require(payload.elements.first { $0.ariaRole == "tab" })
        #expect(tab.role == "AXRadioButton")
        #expect(tab.subrole == "AXTabButton")
    }

    @Test func summaryIsAButton() async throws {
        let payload = try await walk("<details open><summary>More</summary><p>Body</p></details>")
        #expect(roles(payload, tag: "summary") == ["AXButton"])
    }

    @Test func anImageWithNoAltIsStillAnImage() async throws {
        // A deliberate departure from AX, which ignores an unlabelled img: the pixels
        // are an image and the classifier is looking at pixels.
        let payload = try await walk("""
        <svg width="60" height="60"><rect width="60" height="60" fill="blue"></rect></svg>
        """)
        #expect(roles(payload, tag: "svg") == ["AXImage"])
    }

    @Test func explicitAriaBeatsTheTagName() async throws {
        let payload = try await walk("<div role=\"button\" style=\"width:80px;height:30px\">Go</div>")
        #expect(payload.elements.contains { $0.ariaRole == "button" && $0.role == "AXButton" })
    }

    @Test func presentationalRolesEmitNothing() async throws {
        let payload = try await walk("""
        <div role="presentation" style="background:#eee;width:200px;height:80px">
          <span>text</span>
        </div>
        """)
        #expect(!payload.elements.contains { $0.ariaRole == "presentation" })
        // Its text run still counts — the words are on screen either way.
        #expect(payload.elements.contains { $0.role == "AXStaticText" })
    }

    // MARK: - Geometry and visibility

    @Test func displayNoneIsAbsentEntirely() async throws {
        let payload = try await walk("""
        <button style="display:none">Hidden</button>
        <button>Shown</button>
        """)
        let buttons = payload.elements.filter { $0.tag == "button" }
        #expect(buttons.count == 1)
        #expect(buttons[0].text == "Shown")
    }

    @Test func anElementUnderAnOverlayIsNotVisible() async throws {
        let payload = try await walk("""
        <button style="position:absolute;left:20px;top:20px;width:200px;height:60px">Under</button>
        <div style="position:absolute;left:0;top:0;width:400px;height:200px;background:#000"></div>
        """)
        let button = try #require(payload.elements.first { $0.tag == "button" })
        // Reported, but not visible — a dropped element would inflate proposal recall.
        #expect(button.visible == false)
    }

    @Test func aTextRunGetsTheRectOfItsWordsNotItsBlock() async throws {
        // The <p> is full width; the words are not. A run that took the block's rect
        // would teach the model that text is always page-wide.
        let payload = try await walk("<p style=\"width:900px\">Short</p>")
        let run = try #require(payload.elements.first { $0.role == "AXStaticText" })
        #expect(run.rect.width < 400, "the run took its block's width (\(run.rect.width))")
        #expect(run.rect.width > 10)
    }

    @Test func aWrappedRunIsOneElement() async throws {
        let payload = try await walk("""
        <p style="width:200px">one two three four five six seven eight nine ten eleven twelve</p>
        """)
        let runs = payload.elements.filter { $0.role == "AXStaticText" }
        #expect(runs.count == 1, "a wrapped paragraph split into \(runs.count) elements")
        #expect(runs[0].rect.height > 20, "the union should span several lines")
    }

    @Test func contentScrolledOutOfAContainerIsClipped() async throws {
        let payload = try await walk("""
        <div style="height:60px;overflow:auto;width:300px">
          <button style="height:40px">Top</button>
          <div style="height:400px"></div>
          <button style="height:40px">Bottom</button>
        </div>
        """)
        let bottom = payload.elements.first { $0.text == "Bottom" }
        // Either clipped away entirely, or clipped to nothing inside the container.
        if let bottom {
            #expect(bottom.rect.height <= 60, "an off-screen button kept its full height")
        }
        #expect(payload.elements.contains { $0.role == "AXScrollArea" },
                "the overflow container was not recognised")
    }

    @Test func rectsAreInDevicePixels() async throws {
        let payload = try await walk("""
        <div id="a" style="position:absolute;left:100px;top:50px;width:200px;height:80px;background:#333"></div>
        """)
        let box = try #require(payload.elements.first { $0.tag == "div" })
        let dpr = payload.dpr
        #expect(abs(Double(box.rect.x) - 100 * dpr) < 2)
        #expect(abs(Double(box.rect.width) - 200 * dpr) < 2)
    }

    @Test func aPlainLayoutDivIsNotAGroup() async throws {
        // No border, no background: it paints nothing, so it has no box on screen.
        let payload = try await walk("""
        <div style="width:300px;height:120px"><span>inner</span></div>
        <div style="width:300px;height:120px;background:#c0c0c0"></div>
        """)
        let groups = payload.elements.filter { $0.tag == "div" && $0.role == "AXGroup" }
        #expect(groups.count == 1, "expected only the painted div to count, got \(groups.count)")
    }

    // MARK: - Contract

    @Test func groundTruthMarksOnlyVocabularyRolesMatchable() async throws {
        let payload = try await walk("""
        <button>Press</button>
        <div role="progressbar" style="width:200px;height:20px;background:#ccc"></div>
        """)
        let bounds = PixelRect(x: 0, y: 0, width: 4000, height: 4000)
        let truth = payload.groundTruth(imageBounds: bounds)

        let button = try #require(truth.first { $0.role == "AXButton" })
        #expect(button.matchable)
        // Nothing outside the vocabulary may claim a proposal.
        for element in truth where RoleVocabulary.standard.index(of: element.role) == nil {
            #expect(!element.matchable, "\(element.role) is not in the vocabulary but is matchable")
        }
    }

    @Test func theWalkReportsWhatItDid() async throws {
        let payload = try await walk("<button>One</button><p>Two</p>")
        #expect(payload.stats.walked > 0)
        #expect(payload.stats.emitted == payload.elements.count)
        #expect(!payload.stats.truncated)
        #expect(payload.viewport.width == 1000)
    }
}
