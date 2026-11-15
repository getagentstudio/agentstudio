import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AppKit
import Foundation

/// Executes an admitted message action using the source pane's current canonical facts.
struct PaneContextMessageActionRunner: Sendable {
    struct SourceFacts: Sendable {
        let worktreeRoot: URL?
        let cwd: URL?
        let bookmarkedEditorId: EditorTargetId?
    }

    struct Effects: Sendable {
        var editorIsInstalled: @MainActor @Sendable (EditorTargetId) -> Bool
        var openEditor: @MainActor @Sendable (EditorTargetId, URL) async -> Bool
        var openDefault: @MainActor @Sendable (URL) async -> Bool
        var openURL: @MainActor @Sendable (URL) async -> Bool

        @MainActor static var live: Self {
            Self(
                editorIsInstalled: { id in ExternalEditorTarget.refreshInstalledTargets().contains { $0.id == id } },
                openEditor: { id, path in await ExternalWorkspaceOpener.openInEditorAwaiting(id: id, path: path) },
                openDefault: openWithDefaultApplication,
                openURL: openWithDefaultApplication)
        }

        @MainActor private static func openWithDefaultApplication(_ url: URL) async -> Bool {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open(url, configuration: configuration)
                return true
            } catch { return false }
        }
    }

    private let sourceFacts: @MainActor @Sendable (PaneId) -> SourceFacts?
    private let focusPane: @MainActor @Sendable (PaneId) -> Bool
    private let effects: Effects

    @MainActor static func make(
        store: WorkspaceStore, editorPreference: EditorPreferenceAtom, dispatcher: AppCommandDispatcher,
        effects: Effects = .live
    ) -> Self {
        Self(
            sourceFacts: { [weak store] source in
                guard let store, let pane = store.paneAtom.pane(source.uuid) else { return nil }
                return SourceFacts(
                    worktreeRoot: pane.metadata.worktreeId.flatMap { store.repositoryTopologyAtom.worktree($0)?.path },
                    cwd: pane.metadata.cwd, bookmarkedEditorId: editorPreference.bookmarkedEditorId)
            },
            focusPane: { [weak dispatcher] target in
                dispatcher?.dispatch(.focusPane, target: target.uuid, targetType: .pane, executionContext: .interactive)
                    ?? false
            }, effects: effects)
    }

    @concurrent nonisolated func run(_ context: MessageActionContext) async -> MessageActionResult {
        switch context.action {
        case .openFile(let path, _):
            guard let source = await sourceFacts(context.sourcePaneId) else { return .openFile(.sourceUnavailable) }
            guard let url = Self.existingFile(path, source: source) else { return .openFile(.notFound) }
            if let editor = source.bookmarkedEditorId {
                guard await effects.editorIsInstalled(editor) else { return .openFile(.editorUnavailable) }
                return .openFile(await effects.openEditor(editor, url) ? .opened : .launchFailed)
            }
            return .openFile(await effects.openDefault(url) ? .opened : .launchFailed)
        case .openPullRequest(let identity):
            var components = URLComponents()
            components.scheme = "https"
            components.host = identity.host
            components.path = "/\(identity.owner)/\(identity.repository)/pull/\(identity.number)"
            guard let url = components.url else { return .openPullRequest(.failed) }
            return .openPullRequest(await effects.openURL(url) ? .opened : .failed)
        case .goToPane(let target):
            return .goToPane(await focusPane(target) ? .focused : .paneGone)
        }
    }

    private nonisolated static func existingFile(_ path: String, source: SourceFacts) -> URL? {
        let url: URL
        if (path as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: path)
        } else if let base = source.worktreeRoot ?? source.cwd {
            url = base.appending(path: path).standardizedFileURL
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
