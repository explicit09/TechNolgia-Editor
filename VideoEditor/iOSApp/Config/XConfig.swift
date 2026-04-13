import Foundation

/// Compile-time X (Twitter) integration config.
///
/// X's OAuth 2.0 flow for **Public clients** (native apps) uses PKCE only —
/// there is NO client secret. Token exchange runs directly from the device
/// against `https://api.twitter.com/2/oauth2/token`. This mirrors the YouTube
/// pattern (and differs from LinkedIn, which still requires a client secret
/// via an edge function).
///
/// Setup (one-time, see docs/superpowers/setup/x-setup.md):
///   1. developer.x.com → Projects & Apps → create Project → create App
///   2. App → Settings → User authentication settings → Set up
///        - Type: **Public client** (Native app)
///        - App permissions: Read + Write + Media
///        - Callback URI: `com.videoeditor.shorts://x-callback`
///        - Website URL: anything (required)
///   3. Keys and Tokens → OAuth 2.0 Client ID → copy Client ID
///      (NOT the API Key / Secret — those are legacy v1.1)
///   4. Replace `clientID` below with the copied Client ID
///
/// The URL scheme (`com.videoeditor.shorts`) is already registered via the
/// LinkedIn entry in `project.yml`. We reuse the scheme but distinguish by
/// host (`linkedin-callback` vs `x-callback`). ASWebAuthenticationSession
/// delivers the callback URL directly to the running session's completion
/// handler, so there's no AppDelegate routing involved.
enum XConfig {
    /// Public X OAuth 2.0 client ID. Replace before shipping.
    static let clientID = "REPLACE_WITH_CLIENT_ID"

    /// Custom URL scheme callback. Must exactly match the Callback URI
    /// whitelisted in the X developer portal.
    static let redirectURI = "com.videoeditor.shorts://x-callback"

    /// Required OAuth scopes:
    ///   - `tweet.read`      — prerequisite for most user-context endpoints
    ///   - `tweet.write`     — `POST /2/tweets`
    ///   - `users.read`      — `GET /2/users/me`
    ///   - `media.write`     — v2 `/media/upload` (initialize/append/finalize)
    ///   - `offline.access`  — issues a refresh_token
    static let scopes: [String] = [
        "tweet.read",
        "tweet.write",
        "users.read",
        "media.write",
        "offline.access",
    ]

    /// Tweet text character budget (standard tweets on free/basic access).
    static let maxTweetTextLength: Int = 280

    /// Max per-chunk size for `/2/media/upload/:id/append`.
    /// X documents "up to 5 MB"; we use 4 MB for headroom.
    static let mediaUploadChunkSize: Int = 4 * 1024 * 1024

    /// Hosted OAuth 2.0 authorization endpoint.
    static let authorizationEndpoint = URL(string: "https://twitter.com/i/oauth2/authorize")!

    /// OAuth 2.0 token exchange + refresh endpoint.
    static let tokenEndpoint = URL(string: "https://api.twitter.com/2/oauth2/token")!

    /// API v2 base.
    static let apiBase = URL(string: "https://api.twitter.com/2")!

    /// True when a real client ID has been configured.
    static var isConfigured: Bool {
        !clientID.isEmpty && clientID != "REPLACE_WITH_CLIENT_ID"
    }

    /// Scheme portion of `redirectURI` — what ASWebAuthenticationSession uses
    /// to decide when to dismiss itself.
    static var callbackScheme: String? {
        URL(string: redirectURI)?.scheme
    }
}
