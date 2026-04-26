import Foundation

/// Semantic version used for both the SDK API surface and individual
/// plugin versions. Encoded as `"<major>.<minor>.<patch>"` so manifests
/// stay JSON/plist-friendly. Pre-release / build-metadata suffixes are
/// not supported on purpose — the SDK contract is dotted-numeric only,
/// matching the Sparkle releases the host already ships.
public struct SemVer: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = SemVer(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid SemVer string '\(raw)' (expected MAJOR.MINOR.PATCH)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
