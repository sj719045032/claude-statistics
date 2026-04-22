import ApplicationServices
import Foundation

enum AccessibilityFocuser {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func focus(pid: pid_t, projectPath: String? = nil) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let app = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
        guard result == .success,
              let windows = rawWindows as? [AXUIElement],
              let window = preferredWindow(in: windows, projectPath: projectPath)
        else {
            return false
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private static func preferredWindow(in windows: [AXUIElement], projectPath: String?) -> AXUIElement? {
        let hints = FocusProjectLocator.titleHints(for: projectPath).map { $0.lowercased() }
        guard !hints.isEmpty else { return windows.first }

        for window in windows {
            guard let title = windowTitle(window)?.lowercased() else { continue }
            if hints.contains(where: { title.contains($0) }) {
                return window
            }
        }

        return windows.first
    }

    private static func windowTitle(_ window: AXUIElement) -> String? {
        var rawTitle: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle)
        guard result == .success else { return nil }
        return rawTitle as? String
    }
}
