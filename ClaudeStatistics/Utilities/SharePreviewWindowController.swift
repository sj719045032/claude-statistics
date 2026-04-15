import AppKit
import SwiftUI
import TelemetryDeck

enum ShareTelemetrySource: String {
    case periodDetail = "period_detail"
    case providerAllTime = "provider_all_time"
    case allProviders = "all_providers"
}

enum ShareTelemetryAction: String {
    case previewOpened = "share_preview_opened"
    case copyImage = "share_copy_image"
    case copyCaption = "share_copy_caption"
    case savePNG = "share_save_png"
    case systemShare = "share_system_share"
    case socialCompose = "share_social_compose"
    case renderFailed = "share_render_failed"
}

enum ShareTelemetry {
    static func track(
        _ action: ShareTelemetryAction,
        result: ShareRoleResult,
        source: ShareTelemetrySource,
        extra: [String: String] = [:]
    ) {
        var parameters: [String: String] = [
            "source": source.rawValue,
            "role_id": result.roleID.rawValue,
            "provider_mode": result.providerSummary.contains("+") ? "multi" : "single",
            "provider_summary": result.providerSummary,
            "language": LanguageManager.currentLanguageCode ?? "auto"
        ]
        extra.forEach { parameters[$0.key] = $0.value }
        TelemetryDeck.signal(action.rawValue, parameters: parameters)
    }
}

@MainActor
final class SharePreviewWindowController: NSObject, NSWindowDelegate {
    private static var shared: SharePreviewWindowController?

    private var window: NSWindow?
    private var result: ShareRoleResult
    private var source: ShareTelemetrySource

    static func show(result: ShareRoleResult, source: ShareTelemetrySource) {
        if let shared {
            shared.update(result: result, source: source)
            shared.present()
            return
        }

        let controller = SharePreviewWindowController(result: result, source: source)
        shared = controller
        controller.present()
    }

    private init(result: ShareRoleResult, source: ShareTelemetrySource) {
        self.result = result
        self.source = source
        super.init()
        self.window = makeWindow()
        refreshContent()
    }

    private func makeWindow() -> NSWindow {
        let preferredSize = SharePreviewView.preferredContentSize(for: result)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = LanguageManager.localizedString("share.preview.title")
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredSize)).size
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func refreshContent() {
        guard let window else { return }
        window.title = LanguageManager.localizedString("share.preview.title")
        let hostingView = NSHostingView(
            rootView: SharePreviewView(
                result: result,
                source: source,
                onClose: { [weak self] in self?.close() }
            )
        )
        window.contentView = hostingView
        resizeWindowToPreferredContentSize(window)
    }

    private func update(result: ShareRoleResult, source: ShareTelemetrySource) {
        self.result = result
        self.source = source
        refreshContent()
    }

    private func present() {
        guard let window else { return }
        ShareTelemetry.track(.previewOpened, result: result, source: source)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
    }

    private func resizeWindowToPreferredContentSize(_ window: NSWindow) {
        var frame = window.frame
        let preferredSize = SharePreviewView.preferredContentSize(for: result)
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredSize))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.minSize = newFrame.size
        window.setFrame(frame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        if SharePreviewWindowController.shared === self {
            SharePreviewWindowController.shared = nil
        }
    }
}
