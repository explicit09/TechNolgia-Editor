import SwiftUI

struct ProjectBrowserPanel: View {
    @Environment(AppState.self) private var appState
    @State private var isCreating = false
    @State private var newProjectName = ""
    @State private var renamingProject: String?
    @State private var renameText = ""
    @State private var deleteTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if appState.projectIndex.index.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .background(CinematicTheme.surfaceContainerLow)
        .alert("Delete Project?", isPresented: showDeleteAlert, presenting: deleteTarget) { name in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                _ = appState.deleteProject(name: name)
                deleteTarget = nil
            }
        } message: { name in
            Text("This will permanently delete \"\(name)\" and all its media. This cannot be undone.")
        }
    }

    private var showDeleteAlert: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            UtilityPanelHeader(
                eyebrow: "WORKSPACE",
                title: "Projects",
                subtitle: "Switch between projects or create new ones",
                badgeCount: 1,
                showsPrimaryAction: true,
                trailingAccessory: { layout in
                    HStack(spacing: 8) {
                        if layout.showsSecondaryBadges {
                            UtilityStatusBadge(
                                text: "\(appState.projectIndex.index.projects.count) projects",
                                icon: "folder",
                                style: .info
                            )
                        }
                        UtilityHeaderButton(icon: "plus", title: layout.showsSecondaryBadges ? "New" : nil, isProminent: true) {
                            isCreating = true
                            newProjectName = ""
                        }
                    }
                }
            )

            if isCreating {
                createProjectField
            }
        }
    }

    // MARK: - Create Field

    private var createProjectField: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CinematicTheme.primary)

            TextField("Project name", text: $newProjectName)
                .textFieldStyle(.plain)
                .font(.cinTitleSmall)
                .foregroundStyle(CinematicTheme.onSurface)
                .onSubmit { createProject() }

            CinematicToolbarButton(icon: "checkmark", isActive: true) {
                createProject()
            }
            CinematicToolbarButton(icon: "xmark") {
                isCreating = false
            }
        }
        .padding(.horizontal, CinematicSpacing.md)
        .padding(.vertical, CinematicSpacing.xs)
        .background(CinematicTheme.surfaceContainerHigh)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        CinematicEmptyStateBlock(
            icon: "folder",
            title: "No projects yet",
            detail: "Create a project to organize your edits."
        ) {
            CinematicToolbarButton(icon: "plus", label: "New Project", isActive: true) {
                isCreating = true
                newProjectName = ""
            }
        }
    }

    // MARK: - Project List

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(appState.projectIndex.index.projects, id: \.name) { entry in
                    projectRow(entry)
                }
            }
            .padding(CinematicSpacing.md)
        }
    }

    private func projectRow(_ entry: ProjectIndex.ProjectEntry) -> some View {
        let isActive = entry.name == appState.projectIndex.activeProjectName
        let isRenaming = renamingProject == entry.name

        return HStack(spacing: 10) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? CinematicTheme.primary : CinematicTheme.onSurfaceVariant.opacity(0.5))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.cinTitleSmall)
                        .foregroundStyle(CinematicTheme.onSurface)
                        .onSubmit { commitRename(from: entry.name) }
                } else {
                    Text(entry.name)
                        .font(.cinTitleSmall)
                        .foregroundStyle(isActive ? CinematicTheme.primary : CinematicTheme.onSurface)
                        .lineLimit(1)
                }

                Text(formattedDate(entry.modified))
                    .font(.cinLabelRegular)
                    .foregroundStyle(CinematicTheme.onSurfaceVariant.opacity(0.6))
            }

            Spacer()

            if isActive {
                UtilityStatusBadge(text: "ACTIVE", style: .accent)
            }
        }
        .padding(8)
        .background(
            LinearGradient(
                colors: isActive
                    ? [CinematicTheme.primaryContainer.opacity(0.12), CinematicTheme.surfaceContainerHigh.opacity(0.76)]
                    : [CinematicTheme.surfaceContainerLowest, CinematicTheme.surfaceContainerHigh.opacity(0.76)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: CinematicRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: CinematicRadius.lg)
                .strokeBorder(
                    isActive ? CinematicTheme.primary.opacity(0.2) : CinematicTheme.outlineVariant.opacity(0.14),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !isActive else { return }
            Task { _ = await appState.openProject(name: entry.name) }
        }
        .onTapGesture(count: 1) { }
        .help(isActive ? "Active project" : "Double-click to open")
        .contextMenu {
            Button("Open") {
                Task { _ = await appState.openProject(name: entry.name) }
            }
            .disabled(isActive)
            Divider()
            Button("Rename") {
                renameText = entry.name
                renamingProject = entry.name
            }
            Divider()
            Button("Delete", role: .destructive) {
                deleteTarget = entry.name
            }
            .disabled(isActive)
        }
    }

    // MARK: - Actions

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            _ = await appState.createProject(name: name)
            isCreating = false
            newProjectName = ""
        }
    }

    private func commitRename(from oldName: String) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renamingProject = nil
            return
        }
        // Must be the active project to rename
        if oldName == appState.projectIndex.activeProjectName {
            Task { _ = await appState.renameProject(to: name) }
        }
        renamingProject = nil
    }

    // MARK: - Formatting

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
