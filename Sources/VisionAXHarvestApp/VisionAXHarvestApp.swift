//
//  VisionAXHarvestApp.swift
//  VisionAXHarvest
//
//  WHAT: The window the harvester runs in.
//  IN:   main.swift
//  OUT:  HarvestRootView
//

import SwiftUI

struct VisionAXHarvestApp: App {
    @State private var model = HarvestModel()

    var body: some Scene {
        WindowGroup("VisionAX Harvest") {
            HarvestRootView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .task { await model.startIfRequested() }
        }
        .windowResizability(.contentMinSize)
    }
}
