import Foundation

/// Compile-time YouTube integration config.
///
/// Google's OAuth 2.0 flow for installed iOS applications uses PKCE only — there
/// is NO client secret to protect. So unlike LinkedIn we do the entire token
/// exchange directly from the device against `https://oauth2.googleapis.com/token`
/// (no edge function needed).
///
/// Setup (one-time, see docs/superpowers/setup/youtube-setup.md):
///   1. Google Cloud Console → enable "YouTube Data API v3"
///   2. OAuth consent screen → External → add `youtube.upload` and
///      `youtube.force-ssl` scopes; add test users
///   3. Credentials → OAuth client ID → iOS → Bundle ID `com.videoeditor.shorts`
///   4. Replace `clientID` below with the value from the credentials page
///   5. Replace `redirectURI` below with the reverse-DNS form of `clientID`
///      (e.g. clientID `1234567890-abc.apps.googleusercontent.com` →
///      scheme `com.googleusercontent.apps.1234567890-abc`)
///   6. Update the matching URL scheme in `project.yml` → `CFBundleURLTypes`
///      and re-run `xcodegen generate`
enum YouTubeConfig {
    /// Public Google OAuth client ID. Replace before shipping.
    static let clientID = "REPLACE_WITH_CLIENT_ID.apps.googleusercontent.com"

    /// Custom URL scheme registered in `project.yml` → `CFBundleURLTypes`.
    /// Google's iOS OAuth flow requires the reverse-DNS form of the client ID
    /// as the scheme. The path component (`/oauth2callback`) is arbitrary but
    /// must match what we register on the auth URL.
    static let redirectURI = "com.googleusercontent.apps.REPLACE_WITH_CLIENT_ID:/oauth2callback"

    /// Required OAuth scopes:
    ///   - `youtube.upload`     → `videos.insert`
    ///   - `youtube.force-ssl`  → `thumbnails.set`, `channels.list?mine=true`
    static let scopes: [String] = [
        "https://www.googleapis.com/auth/youtube.upload",
        "https://www.googleapis.com/auth/youtube.force-ssl",
    ]

    /// `videos.insert` requires a category id. "22" = People & Blogs, a sane
    /// default for podcast-clip Shorts. Override per-publish if needed.
    static let defaultCategoryID = "22"

    /// Google's hosted authorization endpoint.
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

    /// Google's token exchange + refresh endpoint.
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// YouTube Data API v3 base.
    static let apiBase = URL(string: "https://www.googleapis.com/youtube/v3")!

    /// Resumable upload base for `videos.insert`.
    static let uploadBase = URL(string: "https://www.googleapis.com/upload/youtube/v3")!

    /// True when a real client ID has been configured AND the redirect URI's
    /// reverse-DNS scheme matches it. Google requires the scheme to contain
    /// the numeric prefix of the client ID (e.g. clientID `1234567890-abc...`
    /// → scheme `com.googleusercontent.apps.1234567890-abc`). A mismatch here
    /// would silently break OAuth at runtime, so we fail closed.
    static var isConfigured: Bool {
        guard !clientID.isEmpty,
              !clientID.contains("REPLACE_WITH_CLIENT_ID"),
              !redirectURI.contains("REPLACE_WITH_CLIENT_ID")
        else { return false }
        // The numeric prefix of the client ID must appear in the redirect URI.
        guard let numericPrefix = clientID.split(separator: "-").first.map(String.init),
              !numericPrefix.isEmpty
        else { return false }
        return redirectURI.contains(numericPrefix)
    }

    /// The custom URL scheme portion of `redirectURI` (everything before `:`).
    /// `ASWebAuthenticationSession` matches callbacks against this scheme.
    static var callbackScheme: String? {
        URL(string: redirectURI)?.scheme
    }
}
