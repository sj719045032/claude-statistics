import SwiftUI

struct ProviderBadge: View {
    let provider: ProviderKind
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(provider.badgeColor)
                .frame(width: 8, height: 8)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

extension ProviderKind {
    var badgeColor: Color {
        switch self {
        case .claude: return Color(red: 0.89, green: 0.55, blue: 0.36) // claude orange
        case .gemini: return Color(red: 0.27, green: 0.51, blue: 0.96) // google blue
        case .codex:  return Color(red: 0.18, green: 0.80, blue: 0.44) // openai green
        }
    }
}
