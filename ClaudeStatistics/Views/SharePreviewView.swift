import AppKit
import SwiftUI

struct SharePreviewView: View {
    let result: ShareRoleResult
    let source: ShareTelemetrySource
    let onClose: () -> Void
    @AppStorage(AppPreferences.appLanguage) private var appLanguage = "auto"
    @State private var exportedImage: ExportedShareImage?
    @State private var errorMessage: String?
    @State private var isRendering = false
    @State private var showXSharePrompt = false

    static let exportWidth: CGFloat = 600
    static let previewScale: CGFloat = 0.82
    static let actionRowHeight: CGFloat = 36
    static let contentPadding: CGFloat = 14

    let exportSize: CGSize

    init(result: ShareRoleResult, source: ShareTelemetrySource, onClose: @escaping () -> Void) {
        self.result = result
        self.source = source
        self.onClose = onClose
        self.exportSize = ShareCardLayout.measureExportSize(for: result, width: Self.exportWidth)
    }

    private var previewCardSize: CGSize {
        CGSize(
            width: ceil(exportSize.width * Self.previewScale),
            height: ceil(exportSize.height * Self.previewScale)
        )
    }

    static func preferredContentSize(for result: ShareRoleResult) -> NSSize {
        let exportSize = ShareCardLayout.measureExportSize(for: result, width: exportWidth)
        let previewCardSize = CGSize(
            width: ceil(exportSize.width * previewScale),
            height: ceil(exportSize.height * previewScale)
        )
        return NSSize(
            width: previewCardSize.width + (contentPadding * 2),
            height: previewCardSize.height + actionRowHeight + 12 + (contentPadding * 2)
        )
    }

    var body: some View {
        let cardSize = previewCardSize

        VStack(spacing: 12) {
            previewCard

            actionRow
                .frame(width: cardSize.width, height: Self.actionRowHeight, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(width: cardSize.width, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .padding(Self.contentPadding)
        .fixedSize(horizontal: true, vertical: true)
        .alert(shareText("share.x.prompt.title"), isPresented: $showXSharePrompt) {
            Button(shareText("share.x.prompt.cancel"), role: .cancel) {}
            Button(shareText("share.x.prompt.confirm")) {
                openXComposer()
            }
        } message: {
            Text(shareText("share.x.prompt.message"))
        }
        .task {
            await prepareExportIfNeeded()
        }
    }

    private var previewCard: some View {
        ZStack(alignment: .topLeading) {
            ShareCardView(result: result)
                .frame(width: exportSize.width, height: exportSize.height)
                .scaleEffect(Self.previewScale, anchor: .topLeading)
        }
        .frame(width: previewCardSize.width, height: previewCardSize.height, alignment: .topLeading)
        .clipped()
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await copyImage() }
            } label: {
                Label {
                    Text(verbatim: shareText("share.action.copyImage"))
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            .disabled(isRendering)

            Button {
                Task { await savePNG() }
            } label: {
                Label {
                    Text(verbatim: shareText("share.action.savePNG"))
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .disabled(isRendering)

            Button {
                Task { await shareToX() }
            } label: {
                Label {
                    Text(verbatim: shareText("share.action.shareX"))
                } icon: {
                    Image(systemName: "at")
                }
            }
            .disabled(isRendering)

            if let exportURL = exportedImage?.temporaryURL {
                ShareLink(item: exportURL) {
                    Label {
                        Text(verbatim: shareText("share.action.share"))
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        ShareTelemetry.track(.systemShare, result: result, source: source)
                    }
                )
                .disabled(isRendering)
            } else {
                Button {
                    Task { await prepareExportIfNeeded() }
                } label: {
                    Label {
                        Text(verbatim: shareText("share.action.share"))
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(true)
            }

#if DEBUG
            Button {
                Task { await exportAllRoleCards() }
            } label: {
                Label {
                    Text(verbatim: "Export")
                } icon: {
                    Image(systemName: "square.grid.3x3")
                }
            }
            .disabled(isRendering)
#endif

            Spacer()

            if isRendering {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(.horizontal, 6)
    }

    @MainActor
    private func prepareExportIfNeeded() async {
        if exportedImage != nil || isRendering { return }
        await renderExport()
    }

    @MainActor
    private func copyImage() async {
        if exportedImage == nil {
            await renderExport()
        }
        guard let exportedImage else { return }
        ShareImageExporter.copyToPasteboard(exportedImage)
        ShareTelemetry.track(.copyImage, result: result, source: source)
    }

    @MainActor
    private func savePNG() async {
        if exportedImage == nil {
            await renderExport()
        }
        guard let exportedImage else { return }
        do {
            let savedURL = try ShareImageExporter.saveWithPanel(exportedImage, suggestedFilename: suggestedFilename)
            if savedURL != nil {
                ShareTelemetry.track(.savePNG, result: result, source: source)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func renderExport() async {
        isRendering = true
        errorMessage = nil

        do {
            exportedImage = try ShareImageExporter.render(
                view: ShareCardView(result: result),
                size: exportSize,
                scale: 3.0,
                suggestedFilename: suggestedFilename
            )
        } catch {
            errorMessage = error.localizedDescription
            ShareTelemetry.track(
                .renderFailed,
                result: result,
                source: source,
                extra: ["error": String(describing: error)]
            )
        }

        isRendering = false
    }

    @MainActor
    private func shareToX() async {
        if exportedImage == nil {
            await renderExport()
        }
        guard let exportedImage else { return }

        ShareImageExporter.copyToPasteboard(exportedImage)
        showXSharePrompt = true
    }

#if DEBUG
    @MainActor
    private func exportAllRoleCards() async {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        isRendering = true
        errorMessage = nil

        do {
            for variant in roleVariants {
                let filename = "claude-statistics-role-\(variant.roleID.rawValue)"
                let export = try ShareImageExporter.render(
                    view: ShareCardView(result: variant),
                    size: ShareCardLayout.measureExportSize(for: variant, width: Self.exportWidth),
                    scale: 3.0,
                    suggestedFilename: filename
                )
                let outputURL = folderURL
                    .appendingPathComponent(filename)
                    .appendingPathExtension("png")
                try export.pngData.write(to: outputURL, options: .atomic)
            }
            errorMessage = "Exported \(roleVariants.count) role cards."
        } catch {
            errorMessage = error.localizedDescription
        }

        isRendering = false
    }

    private var roleVariants: [ShareRoleResult] {
        ShareRoleID.allCases.map { role in
            var scores = [ShareRoleScore(roleID: role, score: 0.88)]
            scores.append(contentsOf: ShareRoleID.allCases
                .filter { $0 != role }
                .prefix(2)
                .enumerated()
                .map { index, otherRole in
                    ShareRoleScore(roleID: otherRole, score: index == 0 ? 0.72 : 0.64)
                })

            return ShareRoleResult(
                roleID: role,
                roleName: role.displayName,
                subtitle: result.subtitle,
                summary: result.summary,
                timeScopeLabel: result.timeScopeLabel,
                providerSummary: result.providerSummary,
                visualTheme: role.theme,
                badges: result.badges,
                proofMetrics: result.proofMetrics,
                scores: scores
            )
        }
    }
#endif

    private var suggestedFilename: String {
        let role = result.roleID.rawValue
        let scope = result.timeScopeLabel
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return "claude-statistics-\(role)-\(scope)"
    }

    private var xIntentURL: URL? {
        var components = URLComponents(string: "https://twitter.com/intent/tweet")
        components?.queryItems = [
            URLQueryItem(name: "text", value: socialCaption),
            URLQueryItem(name: "url", value: "https://github.com/sj719045032/claude-statistics")
        ]
        return components?.url
    }

    private var socialCaption: String {
        if LanguageManager.currentLanguageCode == "zh-Hans" {
            return "我的 AI 身份是「\(result.roleName)」：\(result.subtitle)\n#ClaudeStatistics"
        }
        return "My AI identity is \(result.roleName): \(result.subtitle)\n#ClaudeStatistics"
    }

    private func openXComposer() {
        guard let intentURL = xIntentURL else { return }
        NSWorkspace.shared.open(intentURL)
        ShareTelemetry.track(
            .socialCompose,
            result: result,
            source: source,
            extra: ["channel": "x", "image_delivery": "clipboard", "caption_delivery": "prefilled"]
        )
    }

    private func shareText(_ key: String) -> String {
        LanguageManager.localizedString(key)
    }
}

@MainActor
private enum ShareCardLayout {
    private static let minimumHeight: CGFloat = 660

    static func measureExportSize(for result: ShareRoleResult, width: CGFloat) -> CGSize {
        let hostingView = NSHostingView(
            rootView: ShareCardView(result: result)
                .frame(width: width)
        )
        let measured = hostingView.fittingSize
        return CGSize(
            width: width,
            height: ceil(max(measured.height, minimumHeight))
        )
    }
}
