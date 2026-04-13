import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Hashable {
    case library
    case settings
}

@Observable
final class AppState {
    var selectedTab: AppTab = .library
    var shorts: [ShortItem] = MockShorts.library

    // MARK: - Live Supabase state

    @ObservationIgnored
    let supabase = SupabaseShortsClient(
        url: Config.supabaseURL,
        anonKey: Config.supabaseAnonKey
    )

    /// Live shorts pulled from Supabase. Observable so views can react.
    var liveShorts: [Short] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil

    init() {
        VideoCache.configure()
    }

    @MainActor
    func refreshLibrary() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            liveShorts = try await supabase.listShorts()
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    func openLibrary() {
        selectedTab = .library
    }

    func handle(url: URL) {
        guard url.scheme == "technolgia" else { return }
        if url.host == "library" {
            openLibrary()
        }
    }
}
