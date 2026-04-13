import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView(selection: Binding(
            get: { appState.selectedTab },
            set: { appState.selectedTab = $0 }
        )) {
            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Library", systemImage: "play.rectangle.on.rectangle")
            }
            .tag(AppTab.library)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .tag(AppTab.settings)
        }
    }
}
