import SwiftUI
import ClaudeStatisticsKit

struct PluginOnboardingView: View {
    let provider: ProviderKind
    let pluginRegistry: PluginRegistry
    let onReview: (PluginRecommendation?) -> Void
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var scan: PluginRecommendationScan?
    @State private var isScanning = false
    @State private var installingAll = false
    @State private var installedPluginIDs: Set<String> = []
    @State private var restartRequiredIDs: Set<String> = []
    @State private var selectedPluginIDs: Set<String> = []
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 420)
        .task { await runScan() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("onboarding.title")
                    .font(.system(size: 15, weight: .semibold))
                Text("onboarding.subtitle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning && scan == nil {
            VStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("onboarding.scanning")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recommendationsSection
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        let recommendations = scan?.recommendations ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text("onboarding.recommended")
                .font(.system(size: 12, weight: .semibold))
            if recommendations.isEmpty {
                Label("onboarding.recommended.empty", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(recommendations) { recommendation in
                        recommendationRow(recommendation)
                    }
                }
                if let installError {
                    Label(installError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func recommendationRow(_ recommendation: PluginRecommendation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: selectionBinding(for: recommendation)) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(!canSelect(recommendation) || installingAll)
            .frame(width: 18, height: 22, alignment: .top)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(recommendation.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(statusLabel(for: recommendation))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(statusColor(for: recommendation))
                        .clipShape(Capsule())
                }
                Text(recommendation.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(recommendation.pluginID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(9)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Button("onboarding.skip", action: onSkip)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button("onboarding.scanAgain") {
                Task { await runScan() }
            }
            .disabled(isScanning || installingAll)

            if !selectedInstallableRecommendations.isEmpty {
                Button(action: { Task { await installRecommended() } }) {
                    if installingAll {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Text("onboarding.installRecommended")
                    }
                }
                .disabled(installingAll)
                .buttonStyle(.borderedProminent)
            } else if !restartRequiredIDs.isEmpty {
                Button("settings.plugins.restartNow") {
                    AppRelauncher.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                Button("onboarding.reviewPlugins") {
                    onReview(scan?.recommendations.first)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding(12)
    }

    private var installableRecommendations: [PluginRecommendation] {
        (scan?.recommendations ?? []).filter {
            $0.action == .install
                && $0.catalogEntry != nil
                && !installedPluginIDs.contains($0.pluginID)
                && !restartRequiredIDs.contains($0.pluginID)
        }
    }

    private var selectedInstallableRecommendations: [PluginRecommendation] {
        installableRecommendations.filter { selectedPluginIDs.contains($0.pluginID) }
    }

    private func runScan() async {
        isScanning = true
        let nextScan = await PluginRecommendationEngine.scan(
            provider: provider,
            pluginRegistry: pluginRegistry
        )
        scan = nextScan
        selectedPluginIDs = Set(nextScan.recommendations.compactMap { recommendation in
            canSelect(recommendation) ? recommendation.pluginID : nil
        })
        isScanning = false
    }

    private func installRecommended() async {
        guard !selectedInstallableRecommendations.isEmpty else { return }
        installingAll = true
        installError = nil
        let destinationURL = PluginLoader.defaultDirectory

        var installedAny = false
        for recommendation in selectedInstallableRecommendations {
            guard let entry = recommendation.catalogEntry else { continue }
            do {
                let report = try await PluginInstaller.install(
                    entry: entry,
                    into: pluginRegistry,
                    destination: { destinationURL }
                )
                PluginTrustGate.onPluginHotLoaded?(report.manifest, report.bundleURL)
                installedPluginIDs.insert(entry.id)
                installedAny = true
            } catch {
                installError = String(
                    format: NSLocalizedString("onboarding.install.error %@", comment: ""),
                    String(describing: error)
                )
                break
            }
        }

        installingAll = false
        if installedAny {
            onComplete()
        }
    }

    private func statusLabel(for recommendation: PluginRecommendation) -> LocalizedStringKey {
        if restartRequiredIDs.contains(recommendation.pluginID) {
            return "settings.plugins.enable.restartRequired"
        }
        if installedPluginIDs.contains(recommendation.pluginID) {
            return "settings.plugins.discover.installed"
        }
        return recommendation.action == .enable
            ? "settings.plugins.recommendation.enable"
            : "settings.plugins.recommendation.install"
    }

    private func statusColor(for recommendation: PluginRecommendation) -> Color {
        if restartRequiredIDs.contains(recommendation.pluginID) {
            return .orange
        }
        if installedPluginIDs.contains(recommendation.pluginID) {
            return .green
        }
        return recommendation.action == .enable ? .green : .orange
    }

    private func canSelect(_ recommendation: PluginRecommendation) -> Bool {
        recommendation.action == .install
            && recommendation.catalogEntry != nil
            && !installedPluginIDs.contains(recommendation.pluginID)
            && !restartRequiredIDs.contains(recommendation.pluginID)
    }

    private func selectionBinding(for recommendation: PluginRecommendation) -> Binding<Bool> {
        Binding(
            get: { selectedPluginIDs.contains(recommendation.pluginID) },
            set: { selected in
                if selected {
                    selectedPluginIDs.insert(recommendation.pluginID)
                } else {
                    selectedPluginIDs.remove(recommendation.pluginID)
                }
            }
        )
    }
}
