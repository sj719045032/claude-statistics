import Foundation

/// Display-text filters used by the triptych formatter — wrap the pure
/// `DisplayTextClassifier` rules with session-aware fallbacks (e.g. drop
/// raw tool labels for the *current* tool, prefer preview over generic
/// "Working…" text). Every method here returns `nil` to mean "skip this
/// candidate"; the orchestration layer chains them.
extension ProviderSessionDisplayFormatter {
    func firstDisplayLine(
        from candidates: [(text: String?, symbol: String)],
        excluding: String? = nil
    ) -> (text: String, symbol: String)? {
        let excluded = excluding.map(Self.comparableDisplayKey(_:))

        for candidate in candidates {
            guard let value = cleanDisplayText(candidate.text) else { continue }
            if let excluded, Self.comparableDisplayKey(value) == excluded { continue }
            return (value, candidate.symbol)
        }

        return nil
    }

    func filteredOperationText(_ text: String?) -> String? {
        guard let text = cleanDisplayText(text) else { return nil }
        guard !DisplayTextClassifier.isRawToolLabel(text, toolName: session.approvalToolName ?? session.currentToolName) else { return nil }
        return text
    }

    func filteredToolOutputText(_ text: String?) -> String? {
        guard let text = cleanDisplayText(text) else { return nil }
        guard !DisplayTextClassifier.isCodeLikeSnippet(text) else { return nil }
        return text
    }

    func cleanDisplayText(_ text: String?) -> String? {
        guard let text = text?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !DisplayTextClassifier.isInternalMarkupValue(text),
              !DisplayTextClassifier.isNoiseValue(text, noisePrefixes: providerDescriptor.notchNoisePrefixes) else { return nil }
        return text
    }

    func shouldPreferPreviewAsPrimary(over activity: String) -> Bool {
        guard DisplayTextClassifier.isGenericProcessingText(activity) else { return false }
        guard session.currentToolName == nil,
              session.currentToolStartedAt == nil,
              session.activeSubagentCount == 0 else { return false }
        guard let preview = cleanDisplayText(latestPreviewCandidate.text) else { return false }
        return !preview.isEmpty
    }
}
