import SwiftUI

// MARK: - InlineImageView

struct InlineImageView: View {
    let path: String
    private static let maxWidth: CGFloat = 350
    private static let maxHeight: CGFloat = 250

    var body: some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.maxWidth, maxHeight: Self.maxHeight)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .onTapGesture {
                    ImageWindowController.show(nsImage: nsImage, path: path)
                }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Image Window Controller

final class ImageWindowController {
    static func show(nsImage: NSImage, path: String) {
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let maxW = min(nsImage.size.width, screenSize.width * 0.85)
        let maxH = min(nsImage.size.height, screenSize.height * 0.85)
        let ratio = nsImage.size.width / nsImage.size.height
        let winW = min(maxW, maxH * ratio)
        let winH = winW / ratio + 36  // +36 for title bar

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(winW, 400), height: max(winH, 300)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(Int(nsImage.size.width))×\(Int(nsImage.size.height)) — \((path as NSString).lastPathComponent)"
        window.center()
        window.isReleasedWhenClosed = false

        let imageView = NSImageView(image: nsImage)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView

        window.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
