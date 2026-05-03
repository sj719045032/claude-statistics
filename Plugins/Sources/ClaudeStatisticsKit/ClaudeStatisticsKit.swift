import Foundation

/// Public SDK framework for Claude Statistics plugins.
///
/// This file is a placeholder added during rewrite stage B0. The real
/// public surface (Plugin / PluginManifest / ProviderPlugin /
/// TerminalPlugin / ShareRolePlugin / ShareCardThemePlugin and shared
/// models) is filled in during stage 3 of the rewrite. See
/// `docs/REWRITE_PLAN.md` for the staged plan.
public enum SDKInfo {
    /// Semantic version of the SDK API surface. Plugins declare a
    /// `minHostAPIVersion` in their manifest; the host loader rejects
    /// plugins whose required version exceeds this value.
    public static let apiVersion = SemVer(major: 0, minor: 3, patch: 0)
}
