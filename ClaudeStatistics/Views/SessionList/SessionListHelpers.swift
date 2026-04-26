import SwiftUI

func shortModel(_ id: String) -> String {
    id.replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "-2025", with: "")
        .replacingOccurrences(of: "-2024", with: "")
}

func formatCost(_ cost: Double) -> String {
    if cost >= 1.0 { return String(format: "$%.2f", cost) }
    if cost >= 0.01 { return String(format: "$%.3f", cost) }
    return String(format: "$%.4f", cost)
}

func costColor(_ cost: Double) -> Color {
    Theme.costColor(cost)
}
