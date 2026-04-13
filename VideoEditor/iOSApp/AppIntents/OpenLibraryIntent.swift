import AppIntents

struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open TechNolgia Library"
    static let description = IntentDescription("Open the shorts distribution library in the app.")

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct TechNolgiaShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLibraryIntent(),
            phrases: [
                "Open \(.applicationName) library",
                "Show my shorts in \(.applicationName)",
            ],
            shortTitle: "Open Library",
            systemImageName: "play.rectangle.on.rectangle"
        )
    }
}
