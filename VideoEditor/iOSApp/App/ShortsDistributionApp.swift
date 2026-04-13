import SwiftUI

@main
struct ShortsDistributionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .onOpenURL { url in
                    appState.handle(url: url)
                }
        }
    }
}
