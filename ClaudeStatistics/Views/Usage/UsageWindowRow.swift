import SwiftUI

struct UsageWindowRow: View {
    let title: LocalizedStringKey
    let utilization: Double
    let countdown: String?
    var exhaustEstimate: (text: String, willExhaust: Bool)? = nil

    @State private var animatedWidth: CGFloat = 0

    private var color: Color {
        Theme.utilizationColor(utilization)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let estimate = exhaustEstimate {
                    // When willExhaust=false the predicted exhaust time exceeds
                    // the refresh window — drop the "(Nd Nh left)" detail (it's
                    // unactionable and often absurd, e.g. "682d left" on a 7-day
                    // window) and just signal abundance.
                    if estimate.willExhaust {
                        Text("usage.exhaustShort \(estimate.text)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Text("usage.safeRelaxed")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(Theme.quickSpring, value: utilization)
                if let countdown {
                    Text("usage.resetsIn \(countdown)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.15))
                    Capsule()
                        .fill(Theme.utilizationGradient(utilization))
                        .frame(width: animatedWidth)
                        .shadow(color: utilization >= 80 ? color.opacity(0.4) : .clear, radius: 4)
                }
                .onAppear {
                    withAnimation(Theme.springAnimation) {
                        animatedWidth = max(0, geo.size.width * min(utilization / 100.0, 1.0))
                    }
                }
                .onChange(of: utilization) { _, newValue in
                    withAnimation(Theme.springAnimation) {
                        animatedWidth = max(0, geo.size.width * min(newValue / 100.0, 1.0))
                    }
                }
            }
            .frame(height: Theme.progressBarHeight)
        }
    }
}
