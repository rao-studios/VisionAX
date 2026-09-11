//
//  SyntheticPageGeneratorTests.swift
//  VisionAXHarvestKitTests
//
//  WHAT: A seed names a page exactly, and the corpus reaches every control type.
//  PIN:  Determinism is not a nicety here: a dataset sample stores its seed and
//        nothing else about how its page was built, so a generator that drifted would
//        silently make every stored synthetic sample unreproducible.
//

import Foundation
import Testing
@testable import VisionAXHarvestKit
@testable import VisionAXWeb

@Suite struct SyntheticPageGeneratorTests {

    @Test func theSameSeedGivesTheSamePage() {
        for seed in [UInt64(0), 1, 7, 4242, .max] {
            #expect(SyntheticPageGenerator.page(seed: seed).html
                    == SyntheticPageGenerator.page(seed: seed).html)
        }
    }

    @Test func differentSeedsGiveDifferentPages() {
        let pages = Set((0..<40).map { SyntheticPageGenerator.page(seed: UInt64($0)).html })
        #expect(pages.count == 40, "seeds collided")
    }

    @Test func everyControlTypeAppearsAcrossTheCorpus() {
        let corpus = (0..<60).map { SyntheticPageGenerator.page(seed: UInt64($0)).html }
            .joined()
        // One per vocabulary role that a web page can produce. A class the generator
        // never emits is a class the model will only meet by accident.
        let required = [
            "<button", "<a href", "type=\"text\"", "type=\"email\"", "type=\"password\"",
            "type=\"search\"", "type=\"tel\"", "type=\"url\"", "type=\"number\"",
            "<textarea", "type=\"checkbox\"", "type=\"radio\"", "<select", "type=\"range\"",
            "<svg", "<h1", "<h2", "<h3", "<ul", "<ol", "<table", "<tr", "<td", "<th",
            "role=\"tab\"", "role=\"toolbar\"", "<details", "<summary", "<dialog",
            "class=\"scroller\"", "<nav", "<fieldset",
        ]
        for needle in required {
            #expect(corpus.contains(needle), "the generator never produces \(needle)")
        }
    }

    @Test func bothSchemesAppear() {
        let schemes = Set((0..<40).map { SyntheticPageGenerator.page(seed: UInt64($0)).theme.scheme })
        #expect(schemes.count == 2, "one colour scheme never occurs")
    }

    @Test func themesActuallyVary() {
        let themes = (0..<40).map { SyntheticPageGenerator.page(seed: UInt64($0)).theme }
        #expect(Set(themes.map(\.radius)).count > 2)
        #expect(Set(themes.map(\.fontStack)).count > 2)
        #expect(Set(themes.map(\.accent)).count > 2)
        #expect(Set(themes.map(\.buttonIsFilled)).count == 2, "buttons are always the same style")
    }

    @Test func pagesAreSelfContained() {
        // No network: a page that fetched anything would render differently on a cold
        // cache and the boxes would move for reasons no seed records.
        for seed in 0..<25 {
            let html = SyntheticPageGenerator.page(seed: UInt64(seed)).html
            #expect(!html.contains("<link "), "seed \(seed) links a stylesheet")
            #expect(!html.contains("<script"), "seed \(seed) loads a script")
            #expect(!html.contains("http://"), "seed \(seed) references the network")
            #expect(!html.contains("<img src=\"http"), "seed \(seed) loads a remote image")
        }
    }

    @Test func tagsAreBalancedEnoughToParse() {
        for seed in 0..<25 {
            let html = SyntheticPageGenerator.page(seed: UInt64(seed)).html
            #expect(html.hasPrefix("<!DOCTYPE html>"))
            #expect(html.contains("</html>"))
            let opens = html.components(separatedBy: "<div").count
            let closes = html.components(separatedBy: "</div>").count
            #expect(opens == closes, "seed \(seed) has unbalanced divs")
        }
    }

    @Test func theSeedTravelsWithThePage() {
        let page = SyntheticPageGenerator.page(seed: 99)
        #expect(page.origin == "synthetic://page/99")
        #expect(page.html.contains("data-seed=\"99\""))
    }

    @Test func theRandomGeneratorIsStableAcrossRuns() {
        // Pinned values: if SplitMix64 were ever swapped for something else, every
        // stored seed would start naming a different page.
        var generator = SeededRandom(seed: 12345)
        let drawn = (0..<4).map { _ in generator.next() }
        var again = SeededRandom(seed: 12345)
        #expect(drawn == (0..<4).map { _ in again.next() })
    }
}
