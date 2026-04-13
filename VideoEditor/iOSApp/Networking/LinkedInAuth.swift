import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Drives LinkedIn's OAuth 2.0 Authorization Code flow using
/// ASWebAuthenticationSession. We use PKCE for defense-in-depth even though
/// LinkedIn still requires the client_secret at the token-exchange step (which
/// happens server-side in the `linkedin-token-exchange` edge function).
///
/// Flow:
///   1. Build the LinkedIn /oauth/v2/authorization URL with state + PKCE challenge
///   2. ASWebAuthenticationSession opens the LinkedIn page; user signs in
///   3. LinkedIn 302s back to `com.videoeditor.shorts://linkedin-callback?code=...&state=...`
///   4. iOS routes the callback to the session completion handler
///   5. We POST {code, redirect_uri, code_verifier} to the edge function, which
///      adds client_secret and returns LinkedIn's token response
///   6. We call /v2/userinfo to resolve `sub` → `urn:li:person:<sub>`
///   7. Persist `LinkedInTokens` to Keychain
@MainActor
final class LinkedInAuth: NSObject {
    enum AuthError: Error, LocalizedError {
        case notConfigured
        case invalidCallbackURL
        case stateMismatch
        case missingCode(String?)
        case userCancelled
        case underlying(Error)
        case tokenExchangeFailed(Int, String)
        case userInfoFailed(Int, String)
        case decodeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "LinkedIn client ID not set. See docs/superpowers/setup/linkedin-setup.md."
            case .invalidCallbackURL: return "LinkedIn returned an invalid callback URL."
            case .stateMismatch: return "OAuth state mismatch — possible CSRF. Please retry."
            case .missingCode(let detail):
                return "LinkedIn did not return an authorization code." + (detail.map { " (\($0))" } ?? "")
            case .userCancelled: return "Sign-in cancelled."
            case .underlying(let err): return err.localizedDescription
            case .tokenExchangeFailed(let code, let body):
                return "Token exchange failed (HTTP \(code)): \(body)"
            case .userInfoFailed(let code, let body):
                return "Fetching LinkedIn profile failed (HTTP \(code)): \(body)"
            case .decodeFailed(let err): return "Response decode failed: \(err.localizedDescription)"
            }
        }
    }

    /// Runs the full authorization flow and returns persisted, ready-to-use tokens.
    func authorize() async throws -> LinkedInTokens {
        guard LinkedInConfig.isConfigured else { throw AuthError.notConfigured }

        let pkce = PKCE.generate()
        let state = Self.randomURLSafe(byteCount: 24)

        let authURL = try buildAuthorizationURL(state: state, pkceChallenge: pkce.challenge)
        let callback = try await runWebAuthSession(authURL: authURL)

        let (code, returnedState) = try parseCallback(callback)
        guard returnedState == state else { throw AuthError.stateMismatch }

        let tokenResponse = try await exchangeCode(code, codeVerifier: pkce.verifier)
        let userInfo = try await fetchUserInfo(accessToken: tokenResponse.accessToken)

        let tokens = LinkedInTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            memberURN: "urn:li:person:\(userInfo.sub)",
            displayName: userInfo.name
        )
        try TokenStore.save(tokens)
        return tokens
    }

    /// Refreshes the access token using a stored refresh token. Persists the
    /// updated bundle. Throws `notConfigured` if no refresh token is available.
    func refresh(using existing: LinkedInTokens) async throws -> LinkedInTokens {
        guard let refreshToken = existing.refreshToken else {
            throw AuthError.missingCode("No refresh token stored")
        }
        let response = try await postTokenExchange(form: ["refresh_token": refreshToken])
        let updated = LinkedInTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? existing.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            memberURN: existing.memberURN,
            displayName: existing.displayName
        )
        try TokenStore.save(updated)
        return updated
    }

    // MARK: - URL building

    private func buildAuthorizationURL(state: String, pkceChallenge: String) throws -> URL {
        var components = URLComponents(url: LinkedInConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: LinkedInConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: LinkedInConfig.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: LinkedInConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkceChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw AuthError.invalidCallbackURL }
        return url
    }

    // MARK: - ASWebAuthenticationSession

    private var sessionRetainer: ASWebAuthenticationSession?

    private func runWebAuthSession(authURL: URL) async throws -> URL {
        // The custom-scheme path of our redirect URI (e.g. "com.videoeditor.shorts")
        // is what ASWebAuthenticationSession uses to decide when to dismiss.
        guard let scheme = URL(string: LinkedInConfig.redirectURI)?.scheme else {
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
        try await postTokenExchange(form: [
            "code": code,
            "redirect_uri": LinkedInConfig.redirectURI,
            "code_verifier": codeVerifier,
        ])
    }

    private func postTokenExchange(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: LinkedInConfig.tokenExchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Supabase requires the anon key on edge function calls even with verify_jwt=false.
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: form)

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

    // MARK: - User info

    private struct UserInfo: Decodable {
        let sub: String
        let name: String?
        let email: String?
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        var request = URLRequest(url: URL(string: "https://api.linkedin.com/v2/userinfo")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.userInfoFailed(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw AuthError.userInfoFailed(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(UserInfo.self, from: data)
        } catch {
            throw AuthError.decodeFailed(error)
        }
    }

    // MARK: - Helpers

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
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

extension LinkedInAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Find the first foreground window scene's key window. Fallback to a
        // fresh ASPresentationAnchor() (which is `UIWindow()`) if none — this
        // shouldn't happen in normal app states but keeps us safe.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let window = activeScene?.windows.first(where: { $0.isKeyWindow }) ?? activeScene?.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}
