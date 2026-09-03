//
//  WindowCapture.swift
//  VisionAXHarvestKit
//
//  WHAT: One window's pixels via ScreenCaptureKit, and a way to tell if it moved.
//  IN:   AppHarvester
//  OUT:  CGImage + the MEASURED pixels-per-point
//  PIN:  THE SCALE IS MEASURED, NEVER ASSUMED. Requesting width × 2 and believing you
//        got 2× is wrong on a 1× external display and wrong again on any future
//        density; the only honest scale is image.width ÷ window.width after the fact.
//        It is then checked against a whole number, because a fractional scale means
//        the capture was fitted to something rather than rendered at native density,
//        and every rect derived from it would be off by a growing amount across the
//        window.
//

import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum WindowCaptureError: Error, CustomStringConvertible {
    case noMatchingWindow(pid: pid_t)
    case captureFailed(String)
    case oddScale(Double)

    public var description: String {
        switch self {
        case .noMatchingWindow(let pid):
            return "no on-screen window belongs to pid \(pid)"
        case .captureFailed(let reason):
            return "screen capture failed: \(reason)"
        case .oddScale(let scale):
            return "capture scale \(scale) is not a whole number — the image was fitted, not rendered"
        }
    }
}

public struct CapturedWindow: Sendable {
    public var image: CGImage
    /// The window's frame in global top-left points, as ScreenCaptureKit reports it.
    public var frame: CGRect
    public var title: String
    /// Measured pixels per point.
    public var scale: Double
}

public enum WindowCapture {
    /// The frontmost standard window of a process, and its pixels.
    public static func capture(pid: pid_t, matching axFrame: CGRect?) async throws -> CapturedWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.frame.width > 120 && window.frame.height > 120
        }
        guard !candidates.isEmpty else { throw WindowCaptureError.noMatchingWindow(pid: pid) }

        // Prefer the window whose frame matches what AX said, so a walk of window A is
        // never matched against a capture of window B. No private API is needed to pair
        // an AXUIElement with an SCWindow when the geometry already agrees.
        let window: SCWindow
        if let axFrame,
           let paired = candidates.first(where: {
               abs($0.frame.origin.x - axFrame.origin.x) < 2
                   && abs($0.frame.origin.y - axFrame.origin.y) < 2
                   && abs($0.frame.width - axFrame.width) < 2
                   && abs($0.frame.height - axFrame.height) < 2
           }) {
            window = paired
        } else {
            window = candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }!
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let density = filter.pointPixelScale
        configuration.width = Int(filter.contentRect.width * CGFloat(density))
        configuration.height = Int(filter.contentRect.height * CGFloat(density))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
        } catch {
            throw WindowCaptureError.captureFailed(error.localizedDescription)
        }

        let scale = Double(image.width) / Double(window.frame.width)
        guard abs(scale - scale.rounded()) < 0.01 else {
            throw WindowCaptureError.oddScale(scale)
        }

        return CapturedWindow(
            image: image,
            frame: window.frame,
            title: window.title ?? "",
            scale: scale)
    }

    /// How much two captures of the same window differ, 0...1.
    ///
    /// Both are reduced to a small grayscale grid first: the question is whether the
    /// SCREEN changed while the tree was being walked, and antialiasing noise at full
    /// resolution would answer yes every time.
    public static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let width = 64
        let height = 48
        guard let left = grayGrid(a, width: width, height: height),
              let right = grayGrid(b, width: width, height: height)
        else { return 1 }

        var differing = 0
        for index in 0..<(width * height) where abs(Int(left[index]) - Int(right[index])) > 16 {
            differing += 1
        }
        return Double(differing) / Double(width * height)
    }

    private static func grayGrid(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: space,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? pixels : nil
    }
}
