import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("G19 composed message actions", .serialized)
struct PaneContextMessageActionRunnerTests {
    @Test(
        "F11/F16 source worktree wins over CWD, colliding IDs retain their source, absolute paths have no containment")
    func sourcePathsAndContextReachTheComposedRunner() async throws {
        try await withFixture { fixture in
            fixture.preference.setBookmarkedEditor("vscode")
            let id = AgentMessageId.generateUUIDv7()
            for (source, root) in zip(
                [fixture.composition.ownerId, fixture.composition.drawerId], fixture.roots)
            {
                let request = try await fixture.send(.openFile(path: "file.txt", line: 73), source: source, id: id)
                #expect(await fixture.service.runAction(request) == .openFile(.opened))
                #expect(fixture.effects.calls.last == .editor("vscode", root.appending(path: "file.txt")))
                #expect(
                    fixture.effects.contexts.last == .init(sourcePaneId: source, messageId: id, action: request.action))
            }
            let absolute = try await fixture.send(.openFile(path: fixture.outside.path, line: 91))
            #expect(await fixture.service.runAction(absolute) == .openFile(.opened))
            #expect(fixture.effects.calls.last == .editor("vscode", fixture.outside))
            let cwdOnly = try await fixture.send(.openFile(path: "cwd-only.txt", line: nil))
            #expect(await fixture.service.runAction(cwdOnly) == .openFile(.notFound))
            #expect(fixture.effects.calls.count == 3)
        }
    }

    @Test("F16 no worktree uses source CWD; missing targets and missing bases have no launch")
    func cwdFallbackAndMissingPaths() async throws {
        try await withFixture { fixture in
            _ = fixture.store.paneAtom.updatePaneCWDAndResolvedContext(
                fixture.composition.ownerId.uuid, cwd: fixture.cwd, resolvedContext: nil)
            let relative = try await fixture.send(.openFile(path: "file.txt", line: nil))
            #expect(await fixture.service.runAction(relative) == .openFile(.opened))
            #expect(fixture.effects.calls == [.defaultApplication(fixture.cwd.appending(path: "file.txt"))])
            let missing = try await fixture.send(.openFile(path: "missing.txt", line: nil))
            #expect(await fixture.service.runAction(missing) == .openFile(.notFound))
            fixture.store.paneAtom.updatePaneCWD(fixture.composition.ownerId.uuid, cwd: nil)
            try #require(fixture.store.paneAtom.pane(fixture.composition.ownerId.uuid)?.metadata.cwd == nil)
            try #require(fixture.store.paneAtom.pane(fixture.composition.ownerId.uuid)?.metadata.worktreeId == nil)
            #expect(await fixture.service.runAction(relative) == .openFile(.notFound))
            #expect(fixture.effects.calls.count == 1)
        }
    }

    @Test("F11 unavailable bookmark and failed launches remain distinct; no bookmark uses the macOS default route")
    func editorAndLaunchOutcomesRemainDistinct() async throws {
        try await withFixture { fixture in
            let request = try await fixture.send(.openFile(path: "file.txt", line: nil))
            fixture.preference.setBookmarkedEditor("missing-editor")
            fixture.effects.installed = false
            #expect(await fixture.service.runAction(request) == .openFile(.editorUnavailable))
            #expect(fixture.effects.calls.isEmpty)
            fixture.effects.installed = true
            fixture.effects.launchSucceeds = false
            #expect(await fixture.service.runAction(request) == .openFile(.launchFailed))
            #expect(
                fixture.effects.calls.last == .editor("missing-editor", fixture.roots[0].appending(path: "file.txt")))
            fixture.preference.clear()
            #expect(await fixture.service.runAction(request) == .openFile(.launchFailed))
            #expect(fixture.effects.calls.last == .defaultApplication(fixture.roots[0].appending(path: "file.txt")))
            fixture.effects.launchSucceeds = true
            #expect(await fixture.service.runAction(request) == .openFile(.opened))
        }
    }

    @Test("G19 a held opener's eventual failure determines the composed service response")
    func serviceWaitsForTheOpenerResult() async throws {
        try await withFixture { fixture in
            let held = HeldStep<URL>("message action native opener")
            fixture.effects.openHeld = { path in
                do { try await held.arrive(path) } catch { return false }
                return false
            }
            let request = try await fixture.send(.openFile(path: "file.txt", line: nil))
            let operation = Task {
                defer { held.retire() }
                return await fixture.service.runAction(request)
            }
            do {
                let path = try await held.firstArrival()
                #expect(path == fixture.roots[0].appending(path: "file.txt"))
                held.release()
                #expect(await operation.value == .openFile(.launchFailed))
                #expect(held.recordedArrivals.count == 1)
            } catch {
                held.retire()
                operation.cancel()
                _ = await operation.value
                throw error
            }
        }
    }

    @Test(
        "G19 stored action admission precedes effects; retired sources have a typed file outcome before and after restart"
    )
    func admissionAndRetirementRemainAuthoritative() async throws {
        try await withFixture { fixture in
            let request = try await fixture.send(.openFile(path: "file.txt", line: nil))
            let forged = MessageActionRequest(
                messageId: request.messageId, paneId: request.paneId,
                action: .openFile(path: fixture.outside.path, line: nil))
            #expect(await fixture.service.runAction(forged) == .notFound)
            fixture.store.removePane(request.paneId.uuid)
            #expect(await fixture.service.runAction(request) == .openFile(.sourceUnavailable))
            fixture.service.retire([request.paneId])
            #expect(await fixture.service.runAction(request) == .openFile(.sourceUnavailable))
            #expect(await fixture.service.runAction(forged) == .notFound)
            let restarted = fixture.composition.restartComposition()
            #expect(await restarted.paneContextService.runAction(request) == .openFile(.sourceUnavailable))
            await restarted.shutdown()
            #expect(fixture.effects.calls.isEmpty)
            #expect(
                fixture.effects.contexts == [
                    .init(sourcePaneId: request.paneId, messageId: request.messageId, action: request.action)
                ])
        }
    }

    @Test("G19 Go to pane dispatches focusPane for the stored target and reports refusal")
    func focusUsesTheExistingDispatcher() async throws {
        try await withFixture { fixture in
            let target = fixture.composition.drawerId
            let request = try await fixture.send(.goToPane(target))
            #expect(await fixture.service.runAction(request) == .goToPane(.focused))
            #expect(
                fixture.shell.interactions.contains(
                    .targetedExecution(command: .focusPane, target: target.uuid, targetType: .pane)))
            let noOwner = CommandDispatcherFixtureConfiguration().makeDispatcher()
            let runner = PaneContextMessageActionRunner.make(
                store: fixture.store, editorPreference: fixture.preference, dispatcher: noOwner,
                effects: fixture.effects.effects)
            #expect(
                await runner.run(
                    .init(sourcePaneId: request.paneId, messageId: request.messageId, action: request.action))
                    == .goToPane(.paneGone))
            #expect(noOwner.executionOwnerIdentities().shellOwnerID == nil)
            #expect(fixture.effects.calls.isEmpty)
        }
    }

    @Test("F11 stored PR identity wins over the source pane's different cached PR, including launch failure")
    func storedPullRequestIdentityReachesTheOpener() async throws {
        try await withFixture { fixture in
            let cache = RepoCacheAtom()
            let worktree = fixture.repository.worktrees[0]
            cache.setWorktreeEnrichment(
                .init(worktreeId: worktree.id, repoId: fixture.repository.id, branch: "current-branch"))
            let key = try #require(RepoBranchKey(repoId: fixture.repository.id, branch: "current-branch"))
            let cachedURL = try #require(URL(string: "https://github.com/current/repository/pull/999"))
            cache.applyPullRequestFacts([key: .init(openCount: 1, exactOpenURL: cachedURL)])
            let pane = try #require(fixture.store.paneAtom.pane(fixture.composition.ownerId.uuid))
            let paneWorktree = try #require(pane.metadata.worktreeId)
            let branch = try #require(cache.worktreeEnrichment(for: paneWorktree)?.branch)
            let paneKey = try #require(RepoBranchKey(repoId: fixture.repository.id, branch: branch))
            #expect(cache.pullRequestFacts(for: paneKey)?.exactOpenURL == cachedURL)
            let identity = try ForgePullRequestIdentity(
                host: "forge.example", owner: "stored", repository: "project", number: 17)
            let request = try await fixture.send(.openPullRequest(identity))
            let expectedURL = try #require(URL(string: "https://forge.example/stored/project/pull/17"))
            #expect(await fixture.service.runAction(request) == .openPullRequest(.opened))
            #expect(fixture.effects.calls == [.url(expectedURL)])
            #expect(expectedURL != cachedURL)
            fixture.effects.launchSucceeds = false
            #expect(await fixture.service.runAction(request) == .openPullRequest(.failed))
            #expect(fixture.effects.calls == [.url(expectedURL), .url(expectedURL)])
        }
    }

    private func withFixture(_ operation: @MainActor (PaneContextMessageActionFixture) async throws -> Void)
        async throws
    {
        let fixture = try await PaneContextMessageActionFixture.make()
        do {
            try await operation(fixture)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}
