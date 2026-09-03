//
//  main.swift
//  VisionAXBench
//
//  WHAT: The entry point.
//  PIN:  SPM executables launch as background processes. Setting `.regular`
//        before `main()` makes this a real foreground app with a dock icon and
//        a window — same reason Mary's Sources/SandApp/main.swift does it.
//
import AppKit

NSApplication.shared.setActivationPolicy(.regular)
VisionAXBenchApp.main()
