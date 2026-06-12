import SwiftUI
import AppKit
import Combine

@main
struct VideoEditorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase != .active {
                        appState.flushPendingState()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.shutdown()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project...") {
                    createProjectFromPrompt()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save Project") {
                    _ = appState.saveCurrentProject()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { try? appState.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!appState.commandHistory.canUndo)

                Button("Redo") { try? appState.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!appState.commandHistory.canRedo)
            }

            CommandMenu("Project") {
                Button("New Project...") {
                    createProjectFromPrompt()
                }

                Menu("Open Project") {
                    let projects = appState.projectIndex.index.projects.sorted { lhs, rhs in
                        if lhs.modified != rhs.modified {
                            return lhs.modified > rhs.modified
                        }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }

                    ForEach(projects, id: \.name) { entry in
                        Button(entry.name) {
                            openProject(named: entry.name)
                        }
                        .disabled(entry.name == appState.projectIndex.activeProjectName)
                    }
                }

                Button("Save Project") {
                    _ = appState.saveCurrentProject()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Rename Current Project...") {
                    renameCurrentProjectFromPrompt()
                }

                Button("Close Project") {
                    Task { _ = await appState.closeProject() }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            WorkspaceLayoutCommands()
        }
    }

    private func createProjectFromPrompt() {
        guard let name = promptForProjectName(
            title: "New Project",
            message: "Enter a name for the new project."
        ) else {
            return
        }

        Task {
            let result = await appState.createProject(name: name)
            presentProjectResultIfNeeded(result)
        }
    }

    private func renameCurrentProjectFromPrompt() {
        guard let name = promptForProjectName(
            title: "Rename Project",
            message: "Enter a new name for the current project.",
            defaultValue: appState.projectIndex.activeProjectName
        ) else {
            return
        }

        Task {
            let result = await appState.renameProject(to: name)
            presentProjectResultIfNeeded(result)
        }
    }

    private func openProject(named name: String) {
        Task {
            let result = await appState.openProject(name: name)
            presentProjectResultIfNeeded(result)
        }
    }

    private func promptForProjectName(title: String, message: String, defaultValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func presentProjectResultIfNeeded(_ result: String) {
        guard result.hasPrefix("Error:") else { return }

        let alert = NSAlert()
        alert.messageText = "Project Error"
        alert.informativeText = result
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private struct WorkspaceLayoutCommands: Commands {
    @FocusedValue(\.restoreWorkspaceLayoutAction) private var restoreWorkspaceLayoutAction
    @FocusedValue(\.resetWorkspaceLayoutsAction) private var resetWorkspaceLayoutsAction
    @FocusedValue(\.revealAIPanelAction) private var revealAIPanelAction

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Show AI Copilot Panel") {
                revealAIPanelAction?()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(revealAIPanelAction == nil)

            Divider()

            Button("Restore Current Workspace Layout") {
                restoreWorkspaceLayoutAction?()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(restoreWorkspaceLayoutAction == nil)

            Button("Reset All Workspace Layouts") {
                resetWorkspaceLayoutsAction?()
            }
            .disabled(resetWorkspaceLayoutsAction == nil)
        }
    }
}
