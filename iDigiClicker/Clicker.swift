import Foundation
import CoreGraphics
import AppKit

enum Clicker {
    /// Performs a single left mouse click at the given screen point.
    /// Coordinates are in CoreGraphics screen coordinates (origin top-left, points).
    static func click(at point: CGPoint) {
        post(point: point, type: .leftMouseDown, clickCount: 1)
        post(point: point, type: .leftMouseUp,   clickCount: 1)
    }

    /// Performs a double left mouse click at the given screen point.
    static func doubleClick(at point: CGPoint, gapMs: Int = 60) {
        post(point: point, type: .leftMouseDown, clickCount: 1)
        post(point: point, type: .leftMouseUp,   clickCount: 1)
        usleep(useconds_t(max(10, gapMs) * 1000))
        post(point: point, type: .leftMouseDown, clickCount: 2)
        post(point: point, type: .leftMouseUp,   clickCount: 2)
    }

    private static func post(point: CGPoint, type: CGEventType, clickCount: Int64) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
        ev.post(tap: .cghidEventTap)
    }

    /// Whether the process has been granted Accessibility (input control) permission.
    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
