//
//  VisionAXBenchApp.swift
//  VisionAXBench
//
//  WHAT: The bench. Open a desktop screenshot, watch the C engine turn it into
//        an AXTree, and read the JSON that tree encodes to.
//  OUT:  BenchRootView
//  PIN:  Three stages over ONE image and ONE detection — overlay, raw edges, and
//        JSON — so a box that looks wrong can be traced back to the edge map that
//        produced it and forward to the JSON that will ship it.
//
import SwiftUI

struct VisionAXBenchApp: App {
    @State private var model = BenchModel()

    var body: some Scene {
        WindowGroup {
            BenchRootView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .task { model.openLaunchArgumentImage() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Image…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
