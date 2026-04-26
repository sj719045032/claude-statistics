import SwiftUI

struct ToolBarRow: View {
    let name: String
    let count: Int
    let maxCount: Int
    @State private var animatedWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            GeometryReader { geo in
                let target = geo.size.width * CGFloat(count) / CGFloat(max(1, maxCount))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.1))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.5), Color.blue.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: animatedWidth)
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 0.5)) {
                        animatedWidth = target
                    }
                }
            }
            .frame(height: 6)
            .clipped()

            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 35, alignment: .trailing)
        }
    }
}
