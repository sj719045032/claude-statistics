import SwiftUI

/// Simple in-panel toast. Most call sites just emit a one-line success
/// message ("Resume command copied"). The center auto-dismisses after a
/// short delay; calling `show` again cancels the previous timer.
@MainActor
final class ToastCenter: ObservableObject {
    @Published var message: String?
    private var dismissTask: Task<Void, Never>?

    func show(_ msg: String, duration: TimeInterval = 1.5) {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { message = msg }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) { self?.message = nil }
            }
        }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }
}
