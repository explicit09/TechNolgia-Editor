import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Drives Google's OAuth 2.0 flow for installed iOS applications using
/// ASWebAuthenticationSession + PKCE. Unlike LinkedIn, Google's iOS flow has
/// NO client secret, so the entire token exchange happens client-side against
/// `https://oauth2.googleapis.com/token`.
///
/// Flow:
///   1. Build the Google /o/oauth2/v2/auth URL with state + PKCE challenge
///   2. ASWebAuthenticationSession opens the Google sign-in page
///   3. Google 302s back to `com.googleusercontent.apps.<id>:/oauth2callback?code=...&state=...`
///   4. iOS routes the callback to the session completion handler
///   5. We POST {client_id, code, redirect_uri, code_verifier, grant_type} to
///      Google's token endpoint and parse {access_token, refresh_token, expires_in}
///   6. We call /youtube/v3/channels?mine=true to resolve the channel ID + title
///   7. Persist `YouTubeTokens` to Keychain
@MainActor
final class YouTubeAuth: NSObject {
    enum AuthError: Error, LocalizedError {
        case notConfigured
        case invalidCallbackURL
        case stateMismatch
        case missingCode(String?)
        case userCancelled
        case underlying(Error)
        case tokenExchangeFailed(Int, String)
        case channelLookupFailed(Int, String)
        case noChannel
        case decodeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "YouTube client ID not set. See docs/superpowers/setup/youtube-setup.md."
            case .invalidCallbackURL: return "Google returned an invalid callback URL."
            case .stateMismatch: return "OAuth state mismatch — possible CSRF. Please retry."
            case .missingCode(let detail):
                return "Google did not return an authorization code." + (detail.map { " (\($0))" } ?? "")
            case .userCancelled: return "Sign-in cancelled."
            case .underlying(let err): return err.localizedDescription
            case .tokenExchangeFailed(let code, let body):
                return "Token exchange failed (HTTP \(code)): \(body)"
            case .channelLookupFailed(let code, let body):
                return "Channel lookup failed (HTTP \(code)): \(body)"
            case .noChannel:
                return "Google account has no YouTube channel. Create one at youtube.com first."
            case .decodeFailed(let err): return "Response decode failed: \(err.localizedDescription)"
            }
        }
    }

    /// Runs the full authorization flow and returns persisted, ready-to-use tokens.
    func authorize() async throws -> YouTubeTokens {
        guard YouTubeConfig.isConfigured else { throw AuthError.notConfigured }

        let pkce = PKCE.generate()
        let state = Self.randomURLSafe(byteCount: 24)

        let authURL = try buildAuthorizationURL(state: state, pkceChallenge: pkce.challenge)
        let callback = try await runWebAuthSession(authURL: authURL)

        let (code, returnedState) = try parseCallback(callback)
        guard returnedState == state else { throw AuthError.stateMismatch }

        let tokenResponse = try await exchangeCode(code, codeVerifier: pkce.verifier)
        let channel = try await fetchPrimaryChannel(accessToken: tokenResponse.accessToken)

        let tokens = YouTubeTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            channelID: channel.id,
            channelTitle: channel.title
        )
        try TokenStore.youTube.save(tokens)
        return tokens
    }

    /// Refreshes the access token using a stored refresh token. Persists the
    /// updated bundle. Throws if no refresh token is available — caller should
    /// fall back to a full re-authorize.
    func refresh(using existing: YouTubeTokens) async throws -> YouTubeTokens {
        guard let refreshToken = existing.refreshToken else {
            throw AuthError.missingCode("No refresh token stored")
        }
        let response = try await postToken(form: [
            "client_id": YouTubeConfig.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        let updated = YouTubeTokens(
            accessToken: response.accessToken,
            // Google often omits refresh_token on refresh; keep the existing one.
            refreshToken: response.refreshToken ?? existing.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            channelID: existing.channelID,
            channelTitle: existing.channelTitle
        )
        try TokenStore.youTube.save(updated)
        return updated
    }

    // MARK: - URL building

    private func buildAuthorizationURL(state: String, pkceChallenge: String) throws -> URL {
        var components = URLComponents(url: YouTubeConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: YouTubeConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: YouTubeConfig.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: YouTubeConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkceChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // `offline` + `prompt=consent` ensure we get a refresh_token even on
            // re-authorization. Without these Google may skip refresh-token issuance.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw AuthError.invalidCallbackURL }
        return url
    }

    // MARK: - ASWebAuthenticationSession

    private var sessionRetainer: ASWebAuthenticationSession?

    private func runWebAuthSession(authURL: URL) async throws -> URL {
        guard let scheme = YouTubeConfig.callbackScheme else {
            throw AuthError.invalidCallbackURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(throwing: AuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: AuthError.underlying(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.invalidCallbackURL)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.sessionRetainer = session
            session.start()
        }
    }

    private func parseCallback(_ url: URL) throws -> (code: String, state: String?) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidCallbackURL
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let detail = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw AuthError.missingCode(detail)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.missingCode(nil)
        }
        let state = items.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    // MARK: - Token exchange

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> TokenResponse {
        try await postToken(form: [
            "client_id": YouTubeConfig.clientID,
            "code": code,
            "redirect_uri": YouTubeConfig.redirectURI,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
        ])
    }

    private func postToken(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: YouTubeConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncode(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.tokenExchangeFailed(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw AuthError.tokenExchangeFailed(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.decodeFailed(error)
        }
    }

    // MARK: - Channel info

    /// (id, title) of the signed-in user's primary YouTube channel.
    private struct ChannelInfo {
        let id: String
        let title: String?
    }

    private func fetchPrimaryChannel(accessToken: String) async throws -> ChannelInfo {
        var components = URLComponents(url: YouTubeConfig.apiBase.appendingPathComponent("channels"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "mine", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.channelLookupFailed(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw AuthError.channelLookupFailed(http.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let id = first["id"] as? String, !id.isEmpty else {
            throw AuthError.noChannel
        }
        let title = (first["snippet"] as? [String: Any])?["title"] as? String
        return ChannelInfo(id: id, title: title)
    }

    // MARK: - Helpers

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// `application/x-www-form-urlencoded` body for OAuth token requests.
    private static func formURLEncode(_ form: [String: String]) -> String {
        // Sort for deterministic output (helpful for debugging / tests).
        form.keys.sorted().map { key in
            let v = form[key] ?? ""
            return "\(percent(key))=\(percent(v))"
        }.joined(separator: "&")
    }

    private static func percent(_ s: String) -> String {
        // RFC 3986 unreserved set; everything else gets percent-encoded.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - PKCE helper

private struct PKCE {
    let verifier: String
    let challenge: String

    static func generate() -> PKCE {
        // 32 random bytes → 43-char base64url string (verifier).
        var raw = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        let verifier = Data(raw).base64URLEncodedString()

        // SHA256(verifier) base64url encoded → challenge.
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()

        return PKCE(verifier: verifier, challenge: challenge)
    }
}

private extension Data {
    /// RFC 7636 base64url encoding: standard base64 with `+` → `-`, `/` → `_`, no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation context

extension YouTubeAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let window = activeScene?.windows.first(where: { $0.isKeyWindow }) ?? activeScene?.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}
