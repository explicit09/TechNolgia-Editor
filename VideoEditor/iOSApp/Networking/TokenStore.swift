import Foundation
import Security

/// Codable token bundle persisted in the Keychain under the key
/// `linkedin-tokens`. Includes the resolved member URN so the publish flow
/// doesn't need a fresh `/v2/userinfo` call on every post.
struct LinkedInTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Absolute expiration of `accessToken`. UTC.
    var expiresAt: Date
    /// `urn:li:person:<sub>` resolved at sign-in time from `/v2/userinfo`.
    var memberURN: String
    /// Display name resolved from the OIDC `name` claim. Optional; nice-to-have for UI.
    var displayName: String?

    /// True if the access token is still safely usable (with a 60s safety window).
    var isFresh: Bool {
        Date().addingTimeInterval(60) < expiresAt
    }
}

/// Thin Keychain-backed store for `LinkedInTokens`. Uses the generic-password
/// item class with `accessible: AfterFirstUnlock` so background work (e.g.
/// resumed uploads) can still touch the token after device reboot.
///
/// Single key (`linkedin-tokens`) holds the whole JSON-encoded struct as the
/// keychain value. We store the entire bundle as a blob rather than splitting
/// fields so refreshes are atomic.
enum TokenStore {
    private static let service = "com.videoeditor.shorts.linkedin"
    private static let account = "linkedin-tokens"

    enum StoreError: Error, LocalizedError {
        case encodingFailed(Error)
        case decodingFailed(Error)
        case keychainStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let err): return "Encode failed: \(err.localizedDescription)"
            case .decodingFailed(let err): return "Decode failed: \(err.localizedDescription)"
            case .keychainStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    /// Persist tokens, replacing any existing entry.
    static func save(_ tokens: LinkedInTokens) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw StoreError.encodingFailed(error)
        }

        // Delete any prior entry first; SecItemUpdate's matching is fussy when
        // attribute keys differ between add/update calls.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
    }

    /// Load tokens. Returns nil if no entry exists; throws on decode/keychain errors.
    static func load() throws -> LinkedInTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
        guard let data = result as? Data else { return nil }

        do {
            return try JSONDecoder().decode(LinkedInTokens.self, from: data)
        } catch {
            throw StoreError.decodingFailed(error)
        }
    }

    /// Remove tokens. No-op if none exist.
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
