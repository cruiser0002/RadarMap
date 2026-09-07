import Foundation
import CryptoKit

/// AES-256-GCM helpers for encrypting the compact wire arrays used by `TelemetryPacket`
/// and `TacticalIndicator` (see docs/CLOUD_DATA_MANAGEMENT.md §5.E). Gated end-to-end
/// by `AppConstants.Security.telemetryEncryptionEnabled`.
public enum CompactArrayCipherError: Error {
    case malformedCiphertext
    case malformedPlaintext
}

public enum CompactArrayCipher {
    /// Serializes a compact array to JSON, seals it with a fresh random nonce, and returns
    /// `nonce + ciphertext + tag` as a single base64 string (RTDB values must be JSON-safe,
    /// so raw binary can't be stored directly).
    public static func encrypt(_ array: [Any], key: SymmetricKey) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: array)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else {
            throw CompactArrayCipherError.malformedCiphertext
        }
        return combined.base64EncodedString()
    }

    /// Reverses `encrypt(_:key:)`. Throws on a wrong key, corrupted ciphertext, or non-array
    /// plaintext, rather than returning nil, so callers can distinguish "not ciphertext" from
    /// "wrong key" if they ever need to.
    public static func decrypt(_ value: String, key: SymmetricKey) throws -> [Any] {
        guard let data = Data(base64Encoded: value) else {
            throw CompactArrayCipherError.malformedCiphertext
        }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let json = try AES.GCM.open(sealedBox, using: key)
        guard let array = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) as? [Any] else {
            throw CompactArrayCipherError.malformedPlaintext
        }
        return array
    }
}
