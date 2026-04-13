import Foundation
import Security

/// Codable token bundle persisted in the Keychain for LinkedIn. Includes the
/// resolved member URN so the publish flow doesn't need a fresh `/v2/userinfo`
/// call on every post.
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

/// Codable token bundle persisted in the Keychain for YouTube. Stores the
/// resolved channel id + title so the UI can display "Connected: <channel>"
/// without a fresh `/youtube/v3/channels?mine=true` call on every render.
struct YouTubeTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Absolute expiration of `accessToken`. UTC.
    var expiresAt: Date
    /// YouTube channel ID owned by the signed-in Google account.
    var channelID: String
    /// Channel display name (e.g. "TBPN") for the Settings UI.
    var channelTitle: String?

    /// True if the access token is still safely usable (with a 60s safety window).
    var isFresh: Bool {
        Date().addingTimeInterval(60) < expiresAt
    }
}

/// Codable token bundle persisted in the Keychain for X (Twitter). Stores the
/// resolved user id + handle + name so the UI can display "@username" without
/// a fresh `/2/users/me` call on every render. The handle is also used to
/// build the tweet URL after publishing.
struct XTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Absolute expiration of `accessToken`. UTC.
    var expiresAt: Date
    /// X user id (numeric string).
    var userID: String
    /// X handle without the leading `@` (e.g. `tbpn`).
    var username: String
    /// Display name (e.g. "TBPN") for the Settings UI.
    var name: String?

    /// True if the access token is still safely usable (with a 60s safety window).
    var isFresh: Bool {
        Date().addingTimeInterval(60) < expiresAt
    }
}

/// Generic Keychain-backed store for any `Codable` token bundle. Each instance
/// is bound to a `(service, account)` pair so different OAuth providers stay
/// fully isolated in the Keychain.
///
/// Uses the generic-password item class with
/// `accessible: AfterFirstUnlockThisDeviceOnly` so background work (e.g. resumed
/// uploads) can still touch the token after device reboot, while blocking
/// iCloud-backup-based exfiltration of refresh tokens to other devices. The
/// entire encoded blob is stored under one key so refreshes are atomic.
struct TokenStore<Tokens: Codable> {
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

    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// Persist tokens, replacing any existing entry.
    func save(_ tokens: Tokens) throws {
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
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
    }

    /// Load tokens. Returns nil if no entry exists; throws on decode/keychain errors.
    func load() throws -> Tokens? {
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
            return try JSONDecoder().decode(Tokens.self, from: data)
        } catch {
            throw StoreError.decodingFailed(error)
        }
    }

    /// Remove tokens. No-op if none exist.
    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Per-provider singletons

extension TokenStore where Tokens == LinkedInTokens {
    /// LinkedIn token store — service `com.videoeditor.shorts.linkedin`,
    /// account `linkedin-tokens`.
    static let linkedIn = TokenStore<LinkedInTokens>(
        service: "com.videoeditor.shorts.linkedin",
        account: "linkedin-tokens"
    )
}

extension TokenStore where Tokens == YouTubeTokens {
    /// YouTube token store — service `com.videoeditor.shorts.youtube`,
    /// account `youtube-tokens`.
    static let youTube = TokenStore<YouTubeTokens>(
        service: "com.videoeditor.shorts.youtube",
        account: "youtube-tokens"
    )
}

extension TokenStore where Tokens == XTokens {
    /// X (Twitter) token store — service `com.videoeditor.shorts.x`,
    /// account `x-tokens`.
    static let x = TokenStore<XTokens>(
        service: "com.videoeditor.shorts.x",
        account: "x-tokens"
    )
}
