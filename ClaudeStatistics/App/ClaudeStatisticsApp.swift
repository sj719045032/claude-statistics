import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let store = SessionDataStore()
    lazy var sessionViewModel = SessionViewModel(store: store)
    let usageViewModel = UsageViewModel()
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    let notificationService = UsageResetNotificationService.shared
    let zaiUsageViewModel = ZaiUsageViewModel()
    let openAIUsageViewModel = OpenAIUsageViewModel()

    init() {
        store.start()
        notificationService.configure()
        zaiUsageViewModel.setup()
        openAIUsageViewModel.setup()
    }

    func setupZai() {
        zaiUsageViewModel.setup()
    }

    func setupOpenAI() {
        openAIUsageViewModel.setup()
    }
}

struct MenuBarLabel: View {
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var zaiUsageViewModel: ZaiUsageViewModel
    @ObservedObject var openAIUsageViewModel: OpenAIUsageViewModel
    @AppStorage("zaiUsageEnabled") private var zaiUsageEnabled = false
    @AppStorage("openAIUsageEnabled") private var openAIUsageEnabled = false

    var body: some View {
        if menuBarItems.isEmpty {
            Text("--")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        } else {
            // MenuBarExtra normalizes Text labels to the system menu bar foreground color.
            // Render a non-template image so Quotio-style per-provider tinting survives.
            Image(nsImage: menuBarDisplayImage)
                .renderingMode(.original)
                .fixedSize()
        }
    }

    private var menuBarItems: [MenuBarUsageItem] {
        MenuBarUsageSelection.items(
            claudeFiveHourPercent: usageViewModel.menuBarFiveHourPercent,
            zaiFiveHourPercent: zaiUsageViewModel.fiveHourPercent,
            openAIFiveHourPercent: openAIUsageViewModel.currentWindowPercent,
            zaiEnabled: zaiUsageEnabled,
            openAIEnabled: openAIUsageEnabled
        )
    }

    private func color(for role: MenuBarUsageColorRole) -> Color {
        switch role {
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .critical:
            return .red
        }
    }

    private var menuBarDisplayImage: NSImage {
        let fragments = MenuBarUsageSelection.styledFragments(from: menuBarItems)
        let attributedString = NSMutableAttributedString()

        for fragment in fragments {
            attributedString.append(
                NSAttributedString(
                    string: fragment.text,
                    attributes: attributes(for: fragment.style)
                )
            )
        }

        let measuredSize = attributedString.size()
        let imageSize = NSSize(
            width: ceil(measuredSize.width),
            height: max(14, ceil(measuredSize.height))
        )
        let image = NSImage(size: imageSize)
        image.lockFocus()
        attributedString.draw(
            at: NSPoint(
                x: 0,
                y: floor((imageSize.height - measuredSize.height) / 2)
            )
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func attributes(for style: MenuBarUsageTextStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .providerLabel:
            return [
                .font: NSFont.systemFont(ofSize: MenuBarUsageSelection.compactProviderFontSize, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        case .separator:
            return [
                .font: NSFont.systemFont(ofSize: MenuBarUsageSelection.compactProviderFontSize, weight: .regular),
                .foregroundColor: NSColor.white
            ]
        case let .percentage(role):
            return [
                .font: NSFont.monospacedDigitSystemFont(ofSize: MenuBarUsageSelection.compactPercentFontSize, weight: .bold),
                .foregroundColor: NSColor(color(for: role))
            ]
        }
    }
}

@main
struct ClaudeStatisticsApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("appLanguage") private var appLanguage = "auto"

    private var currentLocale: Locale {
        switch appLanguage {
        case "en": Locale(identifier: "en")
        case "zh-Hans": Locale(identifier: "zh-Hans")
        default: Locale.current
        }
    }

    init() {
        LanguageManager.setup()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                usageViewModel: appState.usageViewModel,
                profileViewModel: appState.profileViewModel,
                sessionViewModel: appState.sessionViewModel,
                store: appState.store,
                updaterService: appState.updaterService,
                notificationService: appState.notificationService,
                zaiUsageViewModel: appState.zaiUsageViewModel,
                openAIUsageViewModel: appState.openAIUsageViewModel
            )
            .environment(\.locale, currentLocale)
            .onAppear {
                appState.setupZai()
                appState.setupOpenAI()
            }
        } label: {
            MenuBarLabel(
                usageViewModel: appState.usageViewModel,
                zaiUsageViewModel: appState.zaiUsageViewModel,
                openAIUsageViewModel: appState.openAIUsageViewModel
            )
        }
        .menuBarExtraStyle(.window)
    }
}
