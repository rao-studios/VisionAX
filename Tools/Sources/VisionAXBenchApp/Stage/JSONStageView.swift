//
//  JSONStageView.swift
//  VisionAXBench
//
//  WHAT: The tree as the JSON Mary would decode, with proof that it decodes.
//  IN:   BenchModel.json + roundTripsCleanly
//  OUT:  JSONTextView (AppKit)
//  PIN:  A REAL SCREENSHOT MAKES ~400 KB OF JSON. SwiftUI's Text lays that out as
//        one run inside the scroll view and pins the main thread for minutes —
//        the window keeps animating (Core Animation runs without the main thread)
//        so it looks like a hang, not a slow view. NSTextView pages it instantly.
//        The badge reports a real decode of THIS text back into an
//        AXWindowSnapshot and an equality check against the tree it came from —
//        not a claim that the encoder ran.
//
import AppKit
import SwiftUI

struct JSONStageView: View {
    let model: BenchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Label(
                    model.roundTripsCleanly ? "Decodes back to an identical tree" : "Round-trip failed",
                    systemImage: model.roundTripsCleanly ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(model.roundTripsCleanly ? Color.green : Color.red)
                    .font(.caption.bold())
                Text(verbatim: "\(model.json.utf8.count) bytes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { model.copyJSON() }
                Button("Save…") { model.saveJSON() }
            }
            .padding(10)
            Divider()
            JSONTextView(text: model.json)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// An NSTextView in a scroll view — the one control on this platform that shows a
/// few hundred kilobytes of text without stalling.
private struct JSONTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // No wrapping: a pretty-printed tree's indentation IS its structure, and
        // rewrapping it at the window edge destroys the only depth cue the text has.
        textView.isHorizontallyResizable = true
        let unbounded = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: unbounded, height: unbounded)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard textView.string != text else { return }
        textView.string = text
        textView.scroll(.zero)
    }
}
