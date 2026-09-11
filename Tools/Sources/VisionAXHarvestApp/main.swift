//
//  main.swift
//  VisionAXHarvest
//
//  WHAT: Entry point. Activation policy first, then the SwiftUI app.
//  PIN:  Same recipe as the bench: .regular BEFORE App.main() so the process is a real
//        foreground app with a Dock icon and a window server connection. And the same
//        argv rule — every option is FLAGGED, because AppKit reads a bare argv entry as
//        a document to open and an app with no document type then opens no window at
//        all, which is indistinguishable from a hang.
//

import AppKit
import SwiftUI

NSApplication.shared.setActivationPolicy(.regular)
VisionAXHarvestApp.main()
