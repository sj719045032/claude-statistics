import Foundation

/// Confined to one parsing operation. Reusing formatters avoids constructing
/// them for every projection of every transcript record.
public final class TranscriptTimestampParser {
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()

    public init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        whole.formatOptions = [.withInternetDateTime]
    }

    public func date(_ value: String?) -> Date? {
        value.flatMap { fractional.date(from: $0) ?? whole.date(from: $0) }
    }
}
