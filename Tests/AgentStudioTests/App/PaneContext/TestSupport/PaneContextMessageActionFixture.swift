import AgentStudioEditorChooser
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
final class PaneContextMessageActionEffects {
    enum Call: Equatable {
        case editor(EditorTargetId, URL)
        case defaultApplication(URL)
        case url(URL)
    }
    var installed = true
    var launchSucceeds = true
    var calls: [Call] = []
    var contexts: [MessageActionContext] = []
    var openHeld: (@MainActor @Sendable (URL) async -> Bool)?

    var effects: PaneContextMessageActionRunner.Effects {
        .init(
            editorIsInstalled: { [self] _ in installed },
            openEditor: { [self] editor, path in
                calls.append(.editor(editor, path))
                return await openHeld?(path) ?? launchSucceeds
            },
            openDefault: { [self] path in
                calls.append(.defaultApplication(path))
                return await openHeld?(path) ?? launchSucceeds
            },
            openURL: { [self] url in
                calls.append(.url(url))
                return launchSucceeds
            })
    }
}

@MainActor
struct PaneContextMessageActionFixture {
    let composition: CompositionFactoryFixture
    let store: WorkspaceStore
    let preference: EditorPreferenceAtom
    let effects: PaneContextMessageActionEffects
    let shell: RecordingDispatcherShellCommandOwner
    let dispatcher: AppCommandDispatcher
    let roots: [URL]
    let cwd: URL
    let outside: URL
    let repository: Repo
    var service: PaneContextService { composition.composition.paneContextService }

    static func make(focusSucceeds: Bool = true) async throws -> Self {
        let store = WorkspaceStore(
            identityAtom: .init(workspaceId: UUIDv7.generate()), startsObserving: false)
        let owner = store.createPane(title: "Action owner")
        let preference = EditorPreferenceAtom()
        let effects = PaneContextMessageActionEffects()
        let shell = RecordingDispatcherShellCommandOwner(executionResult: focusSucceeds)
        let dispatcher = CommandDispatcherFixtureConfiguration(shellOwner: shell).makeDispatcher()
        let runner = PaneContextMessageActionRunner.make(
            store: store, editorPreference: preference, dispatcher: dispatcher, effects: effects.effects)
        let composition = try await CompositionFactoryFixture.make(
            ownerId: .init(existingUUID: owner.id),
            messageActionRunner: { context in
                await MainActor.run { effects.contexts.append(context) }
                return await runner.run(context)
            })
        do {
            let roots = [
                composition.root.appending(path: "source-one"), composition.root.appending(path: "source-two"),
            ]
            let cwd = composition.root.appending(path: "cwd")
            let outside = composition.root.appending(path: "outside.txt")
            try await withoutBlockingCooperativePool {
                for directory in roots + [cwd] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data("owned action fixture".utf8).write(to: directory.appending(path: "file.txt"))
                }
                try Data("outside both worktrees".utf8).write(to: outside)
                try Data("CWD must not override a known root".utf8).write(to: cwd.appending(path: "cwd-only.txt"))
            }
            let repositoryId = UUIDv7.generate()
            let worktrees = roots.enumerated().map { index, path in
                Worktree(
                    id: UUIDv7.generate(), repoId: repositoryId, name: "source-\(index)", path: path,
                    isMainWorktree: index == 0)
            }
            let repository = Repo(id: repositoryId, name: "Actions", repoPath: roots[0], worktrees: worktrees)
            guard
                case .prepared(let replacement) = RepositoryTopologyReplacement.prepare(
                    repositories: [repository], watchedPaths: [], unavailableRepositoryIDs: [])
            else { throw ActionFixtureFailure.invalidTopology }
            store.repositoryTopologyAtom.replaceTopology(replacement)
            _ = store.paneAtom.updatePaneCWDAndResolvedContext(
                owner.id, cwd: cwd, resolvedContext: (repository, worktrees[0]))
            _ = store.paneAtom.addDrawerPane(
                to: owner.id, content: owner.content, metadata: owner.metadata,
                childPaneId: composition.drawerId.uuid, expandsDrawer: false)
            _ = store.paneAtom.updatePaneCWDAndResolvedContext(
                composition.drawerId.uuid, cwd: cwd, resolvedContext: (repository, worktrees[1]))
            return Self(
                composition: composition, store: store, preference: preference, effects: effects,
                shell: shell, dispatcher: dispatcher, roots: roots, cwd: cwd, outside: outside,
                repository: repository)
        } catch {
            try? await composition.close()
            throw error
        }
    }

    func send(_ action: MessageAction, source: PaneId? = nil, id: AgentMessageId = .generateUUIDv7()) async throws
        -> MessageActionRequest
    {
        let source = source ?? composition.ownerId
        try #require(
            await service.send(
                .init(
                    paneId: source, messageId: id, sender: .pane(source), sourceOccurredAt: nil,
                    importance: .info, body: "Stored action", why: nil, actions: [action], shape: .notice))
                == .created(id))
        return .init(messageId: id, paneId: source, action: action)
    }

    func close() async throws { try await composition.close() }
}

private enum ActionFixtureFailure: Error { case invalidTopology }
