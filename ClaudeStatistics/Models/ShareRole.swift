import SwiftUI

enum ShareRoleID: String, CaseIterable, Identifiable {
    case vibeCodingKing
    case toolSummoner
    case contextBeastTamer
    case nightShiftEngineer
    case multiModelDirector
    case sprintHacker
    case fullStackPathfinder
    case efficientOperator
    case steadyBuilder

    var id: String { rawValue }

    var displayName: String {
        shareLocalized("share.role.\(rawValue).title")
    }

    var artworkName: String {
        "share_role_\(rawValue)"
    }

    var theme: ShareVisualTheme {
        switch self {
        case .vibeCodingKing:
            return ShareVisualTheme(backgroundTop: .orange, backgroundBottom: .yellow, accent: .black, titleGradient: [.black, .orange, .yellow], titleForeground: .black, titleOutline: .white.opacity(0.28), titleShadowOpacity: 0.08, prefersLightQRCode: false, symbolName: "crown.fill", decorationSymbols: ["terminal", "bolt.fill", "sparkles"], mascotPrimarySymbol: "person.crop.circle.fill", mascotSecondarySymbols: ["crown.fill", "bolt.fill", "terminal.fill"])
        case .toolSummoner:
            return ShareVisualTheme(backgroundTop: .indigo, backgroundBottom: .blue, accent: .white, titleGradient: [.white, .cyan, .mint], titleForeground: .white, titleOutline: .black.opacity(0.24), titleShadowOpacity: 0.16, prefersLightQRCode: true, symbolName: "wand.and.stars.inverse", decorationSymbols: ["wrench.and.screwdriver.fill", "chevron.left.forwardslash.chevron.right", "sparkles"], mascotPrimarySymbol: "person.crop.circle.fill", mascotSecondarySymbols: ["wand.and.stars", "wrench.and.screwdriver.fill", "sparkles"])
        case .contextBeastTamer:
            return ShareVisualTheme(backgroundTop: .teal, backgroundBottom: .indigo, accent: .white, titleGradient: [.white, .mint, .cyan], titleForeground: .white, titleOutline: .black.opacity(0.24), titleShadowOpacity: 0.16, prefersLightQRCode: true, symbolName: "aqi.medium", decorationSymbols: ["rectangle.stack.fill", "scroll.fill", "tortoise.fill"], mascotPrimarySymbol: "person.crop.circle.fill", mascotSecondarySymbols: ["rectangle.stack.fill", "scroll.fill", "sparkles"])
        case .nightShiftEngineer:
            return ShareVisualTheme(backgroundTop: .black, backgroundBottom: .blue, accent: .green, titleGradient: [.green, .cyan, .white], titleForeground: .white, titleOutline: .black.opacity(0.26), titleShadowOpacity: 0.18, prefersLightQRCode: true, symbolName: "moon.stars.fill", decorationSymbols: ["terminal.fill", "moon.fill", "sparkles"], mascotPrimarySymbol: "person.crop.circle.fill", mascotSecondarySymbols: ["moon.stars.fill", "terminal.fill", "sparkles"])
        case .multiModelDirector:
            return ShareVisualTheme(backgroundTop: .pink, backgroundBottom: .indigo, accent: .white, titleGradient: [.white, .pink, .purple], titleForeground: .white, titleOutline: .black.opacity(0.24), titleShadowOpacity: 0.16, prefersLightQRCode: true, symbolName: "theatermasks.fill", decorationSymbols: ["camera.fill", "cpu.fill", "square.stack.3d.up.fill"], mascotPrimarySymbol: "person.crop.circle.fill", mascotSecondarySymbols: ["theatermasks.fill", "camera.fill", "cpu.fill"])
        case .sprintHacker:
            return ShareVisualTheme(backgroundTop: .red, backgroundBottom: .orange, accent: .white, titleGradient: [.white, .yellow, .orange], titleForeground: .white, titleOutline: .black.opacity(0.24), titleShadowOpacity: 0.16, prefersLightQRCode: true, symbolName: "bolt.circle.fill", decorationSymbols: ["flame.fill", "speedometer", "bolt.fill"], mascotPrimarySymbol: "hare.fill", mascotSecondarySymbols: ["bolt.fill", "flame.fill", "sparkles"])
        case .fullStackPathfinder:
            return ShareVisualTheme(backgroundTop: .green, backgroundBottom: .mint, accent: .black, titleGradient: [.black, .green, .mint], titleForeground: .black, titleOutline: .white.opacity(0.28), titleShadowOpacity: 0.08, prefersLightQRCode: false, symbolName: "map.fill", decorationSymbols: ["flag.fill", "point.3.connected.trianglepath.dotted", "shippingbox.fill"], mascotPrimarySymbol: "figure.walk", mascotSecondarySymbols: ["map.fill", "flag.fill", "shippingbox.fill"])
        case .efficientOperator:
            return ShareVisualTheme(backgroundTop: .cyan, backgroundBottom: .mint, accent: .black, titleGradient: [.black, .cyan, .mint], titleForeground: .black, titleOutline: .white.opacity(0.28), titleShadowOpacity: 0.08, prefersLightQRCode: false, symbolName: "dial.high.fill", decorationSymbols: ["gauge.with.dots.needle.50percent", "chart.xyaxis.line", "checkmark.seal.fill"], mascotPrimarySymbol: "person.crop.circle.fill", mascotSecondarySymbols: ["dial.high.fill", "checkmark.seal.fill", "chart.line.uptrend.xyaxis"])
        case .steadyBuilder:
            return ShareVisualTheme(backgroundTop: .gray, backgroundBottom: .blue, accent: .white, titleGradient: [.white, .cyan, .blue], titleForeground: .white, titleOutline: .black.opacity(0.24), titleShadowOpacity: 0.16, prefersLightQRCode: true, symbolName: "hammer.fill", decorationSymbols: ["building.columns.fill", "square.stack.3d.up.fill", "checkmark.circle.fill"], mascotPrimarySymbol: "person.crop.circle.fill", mascotSecondarySymbols: ["hammer.fill", "building.columns.fill", "checkmark.circle.fill"])
        }
    }
}

enum ShareBadgeID: String, CaseIterable, Identifiable {
    case nightOwl
    case cacheWizard
    case opusLoyalist
    case sonnetSpecialist
    case geminiFlashRunner
    case toolAddict
    case projectHopper
    case consistencyMachine
    case costMinimalist
    case peakDayMonster
    case throughputBeast

    var id: String { rawValue }

    var title: String {
        shareLocalized("share.badge.\(rawValue).title")
    }

    var tint: Color {
        switch self {
        case .nightOwl: return .indigo
        case .cacheWizard: return .teal
        case .opusLoyalist: return .purple
        case .sonnetSpecialist: return .blue
        case .geminiFlashRunner: return .green
        case .toolAddict: return .orange
        case .projectHopper: return .mint
        case .consistencyMachine: return .cyan
        case .costMinimalist: return .gray
        case .peakDayMonster: return .red
        case .throughputBeast: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .nightOwl: return "moon.fill"
        case .cacheWizard: return "externaldrive.fill.badge.checkmark"
        case .opusLoyalist: return "music.note.list"
        case .sonnetSpecialist: return "text.book.closed.fill"
        case .geminiFlashRunner: return "bolt.horizontal.fill"
        case .toolAddict: return "wrench.and.screwdriver.fill"
        case .projectHopper: return "folder.fill.badge.plus"
        case .consistencyMachine: return "calendar"
        case .costMinimalist: return "chart.line.downtrend.xyaxis"
        case .peakDayMonster: return "flame.fill"
        case .throughputBeast: return "waveform.path.ecg"
        }
    }

    var category: ShareBadgeCategory {
        switch self {
        case .nightOwl:
            return .schedule
        case .cacheWizard:
            return .context
        case .opusLoyalist, .sonnetSpecialist, .geminiFlashRunner:
            return .model
        case .toolAddict:
            return .tooling
        case .projectHopper:
            return .project
        case .consistencyMachine:
            return .consistency
        case .costMinimalist:
            return .cost
        case .peakDayMonster:
            return .burst
        case .throughputBeast:
            return .output
        }
    }
}

enum ShareBadgeCategory: String {
    case schedule
    case context
    case model
    case tooling
    case project
    case consistency
    case cost
    case burst
    case output
}

struct ShareVisualTheme {
    let backgroundTop: Color
    let backgroundBottom: Color
    let accent: Color
    let titleGradient: [Color]
    let titleForeground: Color
    let titleOutline: Color
    let titleShadowOpacity: Double
    let prefersLightQRCode: Bool
    let symbolName: String
    let decorationSymbols: [String]
    let mascotPrimarySymbol: String
    let mascotSecondarySymbols: [String]
}

struct ShareProofMetric: Identifiable {
    let id = UUID()
    let value: String
    let label: String
    let symbolName: String
}

struct ShareBadge: Identifiable {
    let id: ShareBadgeID
    let title: String
    let symbolName: String
    let tint: Color
}

struct ShareRoleScore: Identifiable {
    let roleID: ShareRoleID
    let score: Double

    var id: ShareRoleID { roleID }
}

struct ShareRoleResult {
    let roleID: ShareRoleID
    let roleName: String
    let subtitle: String
    let summary: String
    let timeScopeLabel: String
    let providerSummary: String
    let visualTheme: ShareVisualTheme
    let badges: [ShareBadge]
    let proofMetrics: [ShareProofMetric]
    let scores: [ShareRoleScore]
}

private func shareLocalized(_ key: String) -> String {
    LanguageManager.localizedString(key)
}
