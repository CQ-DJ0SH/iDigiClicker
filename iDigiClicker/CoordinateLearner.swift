import Foundation
import AppKit
import CoreGraphics

/// Captures the next global left-mouse-click anywhere on screen and reports its
/// CoreGraphics screen-coordinate (origin top-left, points). Returns the point
/// via the completion handler on the main thread.
@MainActor
final class CoordinateLearner {
    private var monitor: Any?
    private var completion: ((CGPoint) -> Void)?

    var isListening: Bool { monitor != nil }

    func start(_ completion: @escaping (CGPoint) -> Void) {
        cancel()
        self.completion = completion
        // Global monitor delivers events from other apps. Requires Accessibility.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            // CGEvent.location is in flipped (top-left origin) screen coords — exactly what we want.
            let p = NSEvent.mouseLocation
            let cg = Self.cocoaToCG(point: p)
            let m = self.monitor
            self.monitor = nil
            if let m { NSEvent.removeMonitor(m) }
            let cb = self.completion
            self.completion = nil
            cb?(cg)
        }
    }

    func cancel() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        completion = nil
    }

    /// NSEvent.mouseLocation uses Cocoa coordinates (origin bottom-left of the
    /// primary screen). Convert to CG screen coordinates (origin top-left) used
    /// by CGEvent and CGWindowList.
    static func cocoaToCG(point p: CGPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else { return p }
        let h = primary.frame.height
        return CGPoint(x: p.x, y: h - p.y)
    }
}
