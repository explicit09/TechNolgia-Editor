import Foundation

/// Compile-time LinkedIn integration config.
///
/// `clientID` is public (it appears in OAuth URLs), so it lives in the bundle.
/// `clientSecret` is NEVER stored client-side — it lives only as a Supabase
/// secret consumed by the `linkedin-token-exchange` edge function.
///
/// Setup (one-time, see docs/superpowers/setup/linkedin-setup.md):
///   1. Create a LinkedIn app at linkedin.com/developers
///   2. Add products: "Sign In with LinkedIn using OpenID Connect" + "Share on LinkedIn"
///   3. Register redirect URI exactly as `redirectURI` below
///   4. Replace `clientID` with the value from the app settings
///   5. `supabase secrets set LINKEDIN_CLIENT_ID=... LINKEDIN_CLIENT_SECRET=... --project-ref vgkocfbtkzmpklruqmsx`
enum LinkedInConfig {
    /// Public LinkedIn OAuth client ID. Replace before shipping.
    static let clientID = "REPLACE_WITH_CLIENT_ID"

    /// Custom URL scheme registered in `project.yml` → `CFBundleURLTypes`.
    /// Must EXACTLY match the redirect URI registered in the LinkedIn dev portal.
    static let redirectURI = "com.videoeditor.shorts://linkedin-callback"

    /// OIDC + posting scopes. `openid profile email` for member URN; `w_member_social` for posting.
    static let scopes: [String] = ["openid", "profile", "email", "w_member_social"]

    /// LinkedIn REST API version pin (YYYYMM). See research doc §6.
    /// Bump monthly — endpoints under older versions deprecate.
    static let apiVersion = "202510"

    /// Supabase edge function URL for the server-side token exchange.
    static var tokenExchangeURL: URL {
        Config.supabaseURL.appendingPathComponent("functions/v1/linkedin-token-exchange")
    }

    /// LinkedIn's hosted authorization endpoint.
    static let authorizationEndpoint = URL(string: "https://www.linkedin.com/oauth/v2/authorization")!

    /// LinkedIn REST API base.
    static let restAPIBase = URL(string: "https://api.linkedin.com")!

    /// True when a real client ID has been configured.
    static var isConfigured: Bool {
        !clientID.isEmpty && clientID != "REPLACE_WITH_CLIENT_ID"
    }
}
