import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportedShareImage {
    let image: NSImage
    let pngData: Data
    let temporaryURL: URL
}

enum ShareImageExporter {
    @MainActor
    static func render<Content: View>(
        view: Content,
        size: CGSize,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0,
        suggestedFilename: String
    ) throws -> ExportedShareImage {
        let content = view
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale

        guard let image = renderer.nsImage else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suggestedFilename)
            .appendingPathExtension("png")
        try pngData.write(to: temporaryURL, options: .atomic)

        return ExportedShareImage(
            image: image,
            pngData: pngData,
            temporaryURL: temporaryURL
        )
    }

    static func copyToPasteboard(_ export: ExportedShareImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([export.image])
    }

    @discardableResult
    static func saveWithPanel(_ export: ExportedShareImage, suggestedFilename: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        try export.pngData.write(to: url, options: .atomic)
        return url
    }
}
