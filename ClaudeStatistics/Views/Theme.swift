import SwiftUI

// MARK: - Design Tokens

enum Theme {
    // MARK: Spacing
    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 12
    static let contentPadding: CGFloat = 12

    // MARK: Corner Radius
    static let cardRadius: CGFloat = 10
    static let badgeRadius: CGFloat = 4
    static let barRadius: CGFloat = 5

    // MARK: Shadows
    static let cardShadowColor = Color.black.opacity(0.06)
    static let cardShadowRadius: CGFloat = 8
    static let cardShadowY: CGFloat = 2

    // MARK: Animation
    static let springAnimation = Animation.spring(duration: 0.35, bounce: 0.15)
    static let quickSpring = Animation.spring(duration: 0.25, bounce: 0.1)
    static let tabAnimation = Animation.spring(duration: 0.3, bounce: 0.2)

    // MARK: Progress Bar
    static let progressBarHeight: CGFloat = 8

    // MARK: Model Colors
    static func modelColor(for model: String) -> Color {
        let m = model.lowercased()
        if m.contains("opus") { return .purple }
        if m.contains("sonnet") { return .blue }
        if m.contains("haiku") { return .teal }
        return .gray
    }

    static func modelBadgeBackground(for model: String) -> Color {
        modelColor(for: model).opacity(0.12)
    }

    static func modelBadgeForeground(for model: String) -> Color {
        modelColor(for: model)
    }

    // MARK: Cost Colors (gradient-friendly)
    static func costColor(_ cost: Double) -> Color {
        if cost > 5.0 { return .red }
        if cost > 1.0 { return .orange }
        return .green
    }

    // MARK: Utilization Gradient
    static func utilizationColor(_ percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .green
    }

    static func utilizationGradient(_ percent: Double) -> LinearGradient {
        let color = utilizationColor(percent)
        return LinearGradient(
            colors: [color.opacity(0.7), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: Bar Chart Gradient
    static func barGradient(_ cost: Double) -> LinearGradient {
        let color = costColor(cost)
        return LinearGradient(
            colors: [color.opacity(0.5), color.opacity(0.85)],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

// MARK: - Reusable View Modifiers

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.cardPadding)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, y: Theme.cardShadowY)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

// MARK: - Chart Interpolation

enum ChartInterpolation {
    /// Linearly interpolate data at the given date. Returns 0 outside data range.
    static func interpolate(at date: Date, in dataPoints: [TrendDataPoint]) -> (tokens: Int, cost: Double) {
        guard !dataPoints.isEmpty else { return (0, 0) }

        let sorted = dataPoints.sorted { $0.time < $1.time }

        // Before first point or after last point → 0
        guard let first = sorted.first, let last = sorted.last else { return (0, 0) }
        if date <= first.time { return (first.tokens, first.cost) }
        if date >= last.time { return (last.tokens, last.cost) }

        // Find bracketing points
        var lo = 0
        var hi = sorted.count - 1
        for i in 0..<sorted.count - 1 {
            if sorted[i].time <= date && date <= sorted[i + 1].time {
                lo = i
                hi = i + 1
                break
            }
        }

        let t0 = sorted[lo].time.timeIntervalSince1970
        let t1 = sorted[hi].time.timeIntervalSince1970
        let t = date.timeIntervalSince1970
        let frac = (t1 > t0) ? (t - t0) / (t1 - t0) : 0

        let tokens = Int(Double(sorted[lo].tokens) + frac * Double(sorted[hi].tokens - sorted[lo].tokens))
        let cost = sorted[lo].cost + frac * (sorted[hi].cost - sorted[lo].cost)
        return (tokens, cost)
    }
}

// MARK: - Hover Scale Button Style

struct HoverScaleButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : isHovered ? 1.15 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: isHovered)
            .animation(.spring(duration: 0.15), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == HoverScaleButtonStyle {
    static var hoverScale: HoverScaleButtonStyle { HoverScaleButtonStyle() }
}

// MARK: - Shimmer Loading Effect

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.15), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 200)
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
