import SwiftUI
import ClaudeStatisticsKit

@MainActor
enum ProviderAccountUIResolver {
    static func makeAccountCardAccessory(
        provider: any SessionProvider,
        pluginRegistry: PluginRegistry,
        context: ProviderSettingsContext,
        triggerStyle: AccountSwitcherTriggerStyle
    ) -> AnyView? {
        if let uiProvider = provider as? any ProviderAccountUIProviding {
            return uiProvider.makeAccountCardAccessory(
                context: context,
                triggerStyle: triggerStyle
            )
        }

        for plugin in pluginRegistry.providers.values {
            guard let providerPlugin = plugin as? any ProviderPlugin,
                  providerPlugin.descriptor.id == provider.providerId,
                  let uiProvider = plugin as? any ProviderAccountUIProviding else {
                continue
            }
            return uiProvider.makeAccountCardAccessory(
                context: context,
                triggerStyle: triggerStyle
            )
        }

        return nil
    }
}
