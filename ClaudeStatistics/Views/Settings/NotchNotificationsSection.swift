import SwiftUI
import ClaudeStatisticsKit

struct NotchNotificationsSection: View {
    let provider: ProviderKind
    let onOpenDetail: () -> Void

    @State private var preferencesRevision = 0
    @State private var isHovered = false

    private var isEnabled: Bool {
        let _ = preferencesRevision
        return NotchPreferences.isEnabled(provider)
    }

    private var available: Bool {
        ProviderRegistry.provider(for: provider).notchHookInstaller != nil
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                NotchPreferences.setEnabled(newValue, for: provider)
                preferencesRevision += 1
            }
        )
    }

    private var titleText: String {
        String(
            format: LanguageManager.localizedString("notch.settings.title.provider"),
            locale: LanguageManager.currentLocale,
            provider.displayName
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(isHovered ? 0.22 : 0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: "bell.badge")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(available && isHovered ? Color.white.opacity(0.95) : .primary)
                Text(available ? summaryText : LanguageManager.localizedString("notch.settings.provider.comingSoon"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(available && isHovered ? Color.white.opacity(0.55) : Color.secondary.opacity(0.55))
                .frame(width: 12, height: 20)

            Toggle("", isOn: masterBinding)
                .labelsHidden()
                .buttonStyle(.borderless)
                .disabled(!available)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard available else {
                isHovered = false
                return
            }
            isHovered = hovering
        }
        .onTapGesture {
            if available { onOpenDetail() }
        }
    }

    private var summaryText: String {
        let supported = ProviderRegistry.provider(for: provider).supportedNotchEvents
        let onCount = supported.filter { event in
            UserDefaults.standard.object(forKey: event.defaultsKey) == nil
                || UserDefaults.standard.bool(forKey: event.defaultsKey)
        }.count
        if !isEnabled {
            return LanguageManager.localizedString("notch.settings.summary.off")
        }
        return String(format: LanguageManager.localizedString("notch.settings.summary.on"), onCount)
    }
}

struct NotchNotificationsDetailView: View {
    let provider: ProviderKind
    let onBack: () -> Void

    @AppStorage(AppPreferences.notchSoundEnabled) private var soundEnabled: Bool = true
    @AppStorage(AppPreferences.notchFocusSilenceEnabled) private var focusSilenceEnabled: Bool = true
    @AppStorage(NotchPreferences.idlePeekDetailedRowsKey) private var idlePeekDetailedRows: Bool = false
    @State private var preferencesRevision = 0

    private var isProviderEnabled: Bool {
        let _ = preferencesRevision
        return NotchPreferences.isEnabled(provider)
    }

    private var titleText: String {
        String(
            format: LanguageManager.localizedString("notch.settings.title.provider"),
            locale: LanguageManager.currentLocale,
            provider.displayName
        )
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { isProviderEnabled },
            set: { newValue in
                NotchPreferences.setEnabled(newValue, for: provider)
                preferencesRevision += 1
            }
        )
    }

    private func eventBinding(for kind: NotchEventKind) -> Binding<Bool> {
        Binding(
            get: {
                let _ = preferencesRevision
                let defaults = UserDefaults.standard
                return defaults.object(forKey: kind.defaultsKey) == nil || defaults.bool(forKey: kind.defaultsKey)
            },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: kind.defaultsKey)
                preferencesRevision += 1
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("settings.back")
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text(providerTitle)
                    .font(.system(size: 13, weight: .semibold))

                Spacer().frame(width: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Form {
                Section("notch.settings.detailSection.global") {
                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "bell.badge")
                        Text(titleText)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("", isOn: masterBinding).labelsHidden()
                    }

                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "speaker.wave.2")
                        Text("notch.settings.sound")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("", isOn: $soundEnabled).labelsHidden()
                    }
                    .disabled(!isProviderEnabled)

                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "eye.slash")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("notch.settings.focusSilence")
                                .font(.system(size: 12, weight: .medium))
                            Text("notch.settings.focusSilence.hint")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $focusSilenceEnabled).labelsHidden()
                    }
                    .disabled(!isProviderEnabled)

                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "list.bullet.rectangle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("notch.settings.detailedRows")
                                .font(.system(size: 12, weight: .medium))
                            Text("notch.settings.detailedRows.hint")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $idlePeekDetailedRows).labelsHidden()
                    }

                    if isProviderEnabled {
                        NotchScreenPickerRow()
                    }
                }

                let supported = ProviderRegistry.provider(for: provider).supportedNotchEvents
                if !supported.isEmpty {
                    Section(providerTitle) {
                        ForEach(NotchEventKind.allCases.filter(supported.contains), id: \.self) { kind in
                            eventToggleRow(
                                icon: kind.icon,
                                titleKey: kind.titleKey,
                                binding: eventBinding(for: kind)
                            )
                            .disabled(!isProviderEnabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var providerTitle: String {
        ProviderRegistry.provider(for: provider).displayName
    }

    private func eventToggleRow(icon: String, titleKey: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            SettingsRowIcon(name: icon)
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Toggle("", isOn: binding).labelsHidden()
        }
    }
}

private struct NotchScreenPickerRow: View {
    @AppStorage(NotchPreferences.screenSelectionKey) private var screenSelection = NotchPreferences.mainScreenSelection
    @State private var screenRevision = 0

    private var screens: [NSScreen] {
        let _ = screenRevision
        return NSScreen.screens
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { normalizedSelection },
            set: { newValue in
                screenSelection = newValue
                NotchPreferences.setScreenSelection(newValue)
            }
        )
    }

    private var normalizedSelection: String {
        if screenSelection == NotchPreferences.mainScreenSelection {
            return screenSelection
        }
        let availableIDs = Set(screens.map(notchScreenIdentifier))
        return availableIDs.contains(screenSelection) ? screenSelection : NotchPreferences.mainScreenSelection
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(name: "display")
            Text("notch.settings.screen")
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Picker("", selection: selectionBinding) {
                Text("notch.settings.screen.main")
                    .tag(NotchPreferences.mainScreenSelection)

                ForEach(screens, id: \.notchSettingsID) { screen in
                    Text(screenLabel(screen))
                        .tag(notchScreenIdentifier(screen))
                }
            }
            .labelsHidden()
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear {
            normalizeSelectionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenRevision &+= 1
            normalizeSelectionIfNeeded()
        }
    }

    private func screenLabel(_ screen: NSScreen) -> String {
        let base = screen.localizedName
        let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        let suffix: String
        if screenHasNotch(screen) {
            suffix = LanguageManager.localizedString("notch.settings.screen.notch")
        } else if isSameAsMain(screen) {
            suffix = LanguageManager.localizedString("notch.settings.screen.currentMain")
        } else {
            suffix = size
        }
        return "\(base) · \(suffix)"
    }

    private func isSameAsMain(_ screen: NSScreen) -> Bool {
        guard let main = NSScreen.main else { return false }
        return notchScreenIdentifier(screen) == notchScreenIdentifier(main)
    }

    private func normalizeSelectionIfNeeded() {
        let normalized = normalizedSelection
        guard normalized != screenSelection else { return }
        screenSelection = normalized
        NotchPreferences.setScreenSelection(normalized)
    }
}

private extension NSScreen {
    var notchSettingsID: String { notchScreenIdentifier(self) }
}
