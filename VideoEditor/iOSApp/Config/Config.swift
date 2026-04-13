import Foundation
import SwiftUI

/// Compile-time configuration. Credentials are baked in; this is a two-user private app.
/// If you open-source this repo, move these to a local, gitignored config.
enum Config {
    static let appName = "TechNolgia"

    // Replace these with your actual values from Supabase → Settings → API.
    static let supabaseURL = URL(string: "https://REPLACE_WITH_PROJECT_REF.supabase.co")!
    static let supabaseAnonKey = "REPLACE_WITH_ANON_KEY"

    /// Brand color palette for thumbnail pill. Order matters — UI shows these left-to-right.
    static let brandPalette: [BrandColor] = [
        BrandColor(name: "Gold", hex: "#C9A028"),
        BrandColor(name: "Navy", hex: "#070D17"),
        BrandColor(name: "White", hex: "#FFFFFF"),
        BrandColor(name: "Pink", hex: "#E91E63"),
        BrandColor(name: "Green", hex: "#00C853"),
    ]

    struct BrandColor: Identifiable, Hashable {
        let name: String
        let hex: String
        var id: String { hex }

        /// Backwards-compat convenience for existing views that consumed `brand.color` directly.
        var color: Color {
            let raw = hex.replacingOccurrences(of: "#", with: "")
            guard raw.count == 6, let value = Int(raw, radix: 16) else { return .white }
            return Color(
                red: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0
            )
        }
    }
}
