import SwiftUI

struct BackupRestoreView: View {
    let onBack: () -> Void
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var showRestartAlert = false
    @State private var importManifest: BackupService.Manifest?
    @State private var pendingImportURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                exportSection
                importSection
            }
            .formStyle(.grouped)
        }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("settings.back")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("backup.export.description")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("backup.export.dbSize")
                        .font(.system(size: 12))
                    Spacer()
                    Text(formattedDBSize)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Button(action: exportBackup) {
                    HStack {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("backup.export.button")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isExporting)
            }
        } header: {
            Label("backup.export", systemImage: "arrow.up.doc")
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("backup.import.description")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button(action: importBackup) {
                    HStack {
                        if isImporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("backup.import.button")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isImporting)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(statusMessage.contains("✓") ? .green : .red)
                }
            }
        } header: {
            Label("backup.import", systemImage: "arrow.down.doc")
        }
        .alert("backup.import.confirm.title", isPresented: Binding(
            get: { importManifest != nil },
            set: { if !$0 { importManifest = nil; pendingImportURL = nil } }
        )) {
            Button("backup.import.confirm.cancel", role: .cancel) {
                importManifest = nil
                pendingImportURL = nil
            }
            Button("backup.import.confirm.proceed") {
                performImport()
            }
        } message: {
            if let m = importManifest {
                Text(String(format: LanguageManager.localizedString("backup.import.confirm.message"),
                            m.appVersion, formattedDate(m.date), m.sessionCount))
            }
        }
        .alert("backup.import.restart.title", isPresented: $showRestartAlert) {
            Button("backup.import.restart.button") {
                restartApp()
            }
        } message: {
            Text("backup.import.restart.message")
        }
    }

    // MARK: - Actions

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "csbackup")!]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "claude-statistics-\(formatter.string(from: Date())).csbackup"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BackupService.shared.exportBackup(to: url)
                DispatchQueue.main.async {
                    isExporting = false
                    statusMessage = "✓ " + LanguageManager.localizedString("backup.export.success")
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "csbackup")!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let manifest = try BackupService.shared.peekManifest(at: url)
            pendingImportURL = url
            importManifest = manifest
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }
        importManifest = nil
        pendingImportURL = nil
        isImporting = true
        statusMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BackupService.shared.importBackup(from: url)
                DispatchQueue.main.async {
                    isImporting = false
                    showRestartAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    isImporting = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func restartApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Formatting

    private var formattedDBSize: String {
        ByteCountFormatter.string(fromByteCount: BackupService.shared.databaseSize, countStyle: .file)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
