import CryptoKit
import Foundation
import Security

/// PKCE (Proof Key for Code Exchange) helper for the Claude OAuth flow.
struct ClaudePKCE {
    let codeVerifier: String
    let codeChallenge: String

    static func generate() -> ClaudePKCE {
        let verifierBytes = randomBytes(count: 32)
        let verifier = Data(verifierBytes).base64URLEncodedString()

        let challengeDigest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(challengeDigest).base64URLEncodedString()

        return ClaudePKCE(codeVerifier: verifier, codeChallenge: challenge)
    }

    /// 32-char hex state token, matching the format CLIProxyAPI uses.
    /// Anthropic's authorize endpoint rejects requests whose `state` isn't in this form.
    static func generateState() -> String {
        randomBytes(count: 16).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
