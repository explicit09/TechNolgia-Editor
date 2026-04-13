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
