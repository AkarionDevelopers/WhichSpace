import AppKit
import SwiftUI

/// The Projects settings pane: automatic labels from git branches, the
/// project folders used for window-title matching, and the Claude Code
/// session-status indicator with its hook installer.
/// Container-agnostic - it knows nothing about the window chrome hosting it.
struct ProjectsPane: View {
    let model: SettingsModel
    let appState: AppState

    @State private var hooksState: ClaudeCodeHooks.InstallState = .notInstalled

    var body: some View {
        SettingsForm {
            if !model.accessibilityGranted {
                accessibilityBanner
            }
            autoLabelSection
            projectRootsSection
            agentStatusSection
            diagnosticsSection
        }
        .onAppear {
            hooksState = ClaudeCodeHooks.installState()
        }
    }

    /// Window titles are read through the Accessibility API, so nothing on
    /// this pane can work without the permission.
    private var accessibilityBanner: some View {
        SettingsSection {
            SettingsRow {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Localization.alertAccessibilityRequired)
                            .fontWeight(.semibold)
                        Text(Localization.bannerAccessibilityDetail)
                            .foregroundStyle(.secondary)
                    }
                }
            } control: {
                Button(Localization.actionOpenSystemSettings) {
                    model.requestAccessibility()
                    Accessibility.openSettingsPane()
                }
            }
        }
    }

    // MARK: - Automatic Labels

    private var autoLabelSection: some View {
        let enabled = model.value(\.autoLabelFromProject)
        return SettingsSection {
            SettingsToggleRow(
                title: Localization.toggleAutoLabel,
                isOn: model.binding(\.autoLabelFromProject),
                icon: "arrow.triangle.branch",
                subtitle: Localization.tipAutoLabel
            )
            SettingsRowDivider()
            SettingsRow(
                icon: "curlybraces",
                subtitle: Localization.tipLabelTemplate,
                disabled: !enabled,
                indented: true
            ) {
                Text(Localization.labelLabelTemplate)
                    .foregroundStyle(enabled ? .primary : .tertiary)
            } control: {
                TextField(Localization.labelLabelTemplate, text: model.binding(\.autoLabelTemplate))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 140)
            }
        }
    }

    // MARK: - Project Roots

    private var projectRootsSection: some View {
        SettingsSection {
            SettingsRow(icon: "folder.badge.gearshape", subtitle: Localization.tipProjectRoots) {
                Text(Localization.labelProjectRoots)
            } control: {
                Button(Localization.actionAddFolder) {
                    addProjectRoot()
                }
            }
            ForEach(model.value(\.projectRoots), id: \.self) { root in
                SettingsRowDivider()
                SettingsRow(indented: true) {
                    Text(root)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                } control: {
                    Button {
                        removeProjectRoot(root)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Localization.buttonReset)
                }
            }
        }
    }

    private func addProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let binding = model.binding(\.projectRoots)
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        guard !binding.wrappedValue.contains(path) else {
            return
        }
        binding.wrappedValue.append(path)
    }

    private func removeProjectRoot(_ root: String) {
        let binding = model.binding(\.projectRoots)
        binding.wrappedValue.removeAll { $0 == root }
    }

    // MARK: - Claude Code

    private var agentStatusSection: some View {
        SettingsSection {
            SettingsToggleRow(
                title: Localization.toggleAgentStatus,
                isOn: agentIndicatorBinding,
                icon: "circle.inset.filled",
                subtitle: Localization.tipAgentStatus
            )
            SettingsRowDivider()
            SettingsRow(icon: "link", subtitle: Localization.tipHooks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Localization.labelHooks)
                    Text(hooksStateLabel)
                        .font(.system(size: Layout.settingsRowSubtitleFontSize))
                        .foregroundStyle(hooksState == .installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
            } control: {
                if hooksState == .installed {
                    Button(Localization.actionRemoveHooks) {
                        removeHooks()
                    }
                } else {
                    Button(Localization.actionInstallHooks) {
                        installHooks()
                    }
                }
            }
        }
    }

    private var agentIndicatorBinding: Binding<Bool> {
        let stored = model.binding(\.agentStatusIndicator)
        return Binding(
            get: { stored.wrappedValue != .off },
            set: { stored.wrappedValue = $0 ? .dot : .off }
        )
    }

    private var hooksStateLabel: String {
        switch hooksState {
        case .installed:
            Localization.statusHooksInstalled
        case .notInstalled:
            Localization.statusHooksNotInstalled
        case .partial:
            Localization.statusHooksPartial
        }
    }

    private func installHooks() {
        guard ConfirmationAlert(
            message: Localization.confirmInstallHooks,
            detail: Localization.detailInstallHooks,
            confirmTitle: Localization.buttonOK,
            isDestructive: false
        ).runModal() else {
            return
        }
        do {
            try ClaudeCodeHooks.install()
        } catch {
            NSLog("ProjectsPane: hook install failed - %@", error.localizedDescription)
        }
        hooksState = ClaudeCodeHooks.installState()
    }

    private func removeHooks() {
        guard ConfirmationAlert(
            message: Localization.confirmRemoveHooks,
            detail: Localization.detailRemoveHooks,
            confirmTitle: Localization.buttonOK,
            isDestructive: true
        ).runModal() else {
            return
        }
        do {
            try ClaudeCodeHooks.remove()
        } catch {
            NSLog("ProjectsPane: hook removal failed - %@", error.localizedDescription)
        }
        hooksState = ClaudeCodeHooks.installState()
    }

    // MARK: - Diagnostics

    /// Live view of what the index resolved - the fastest way to see why a
    /// Space is not labelling (no window found, name not matched, no repo).
    private var diagnosticsSection: some View {
        let projects = appState.projectIndex.projects.values.sorted { $0.name < $1.name }
        let states = appState.agentStatusStore.statesBySpace
        return SettingsSection(Localization.labelDetectedProjects) {
            if projects.isEmpty {
                SettingsRow {
                    Text(Localization.labelNoProjects)
                        .foregroundStyle(.secondary)
                } control: {
                    EmptyView()
                }
            }
            ForEach(Array(projects.enumerated()), id: \.element.spaceID) { index, project in
                if index > 0 {
                    SettingsRowDivider()
                }
                SettingsRow(icon: "folder") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                        if let branch = project.branch {
                            Text(branch)
                                .font(.system(size: Layout.settingsRowSubtitleFontSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                } control: {
                    if let state = states[project.spaceID] {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(nsColor: state.indicatorColor))
                                .frame(width: 8, height: 8)
                            Text(agentStateLabel(state))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func agentStateLabel(_ state: AgentState) -> String {
        switch state {
        case .working:
            Localization.agentStateWorking
        case .waiting:
            Localization.agentStateWaiting
        case .done:
            Localization.agentStateDone
        }
    }
}
