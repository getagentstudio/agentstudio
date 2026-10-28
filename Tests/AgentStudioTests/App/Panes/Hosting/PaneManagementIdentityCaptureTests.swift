import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer
@testable import AgentStudioSessions

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityCaptureTests {
    @Test("card terminal titles use the sidebar's normalized name", arguments: ["/tmp/project", ""])
    func terminalTitleMatchesSidebarNormalization(liveTitle: String) async {
        let input = PaneManagementIdentityCapture.LineInput(
            paneId: UUIDv7.generate(), terminalTitle: liveTitle, cwd: URL(filePath: "/tmp/project"),
            shellExecutablePath: "/bin/zsh", agentTitle: nil, note: nil, isDrawer: false,
            agentLine: nil, sessionPresentation: nil)

        let lines = await PaneManagementIdentityCapture.lines(input, now: .distantPast)

        #expect(lines.first == .title("zsh"))
        #expect(
            lines.first
                == .title(
                    PaneContextPresentationRules.displayTitle(
                        raw: liveTitle, cwd: input.cwd, shell: "/bin/zsh")))
    }

    enum SessionMode: CaseIterable, Sendable { case unbound, live, ended, unverified }

    @Test("only a verified live binding contributes a SESSION identity", arguments: SessionMode.allCases)
    func sessionIdentityRequiresVerifiedLiveBinding(mode: SessionMode) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.withIngestion { ingestion, _ in
            try await Self.checkSessionIdentity(mode: mode, ingestion: ingestion)
        }
    }

    private static func checkSessionIdentity(mode: SessionMode, ingestion: SessionsIngestion) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Terminal")
            let paneId = PaneId(existingUUID: pane.id)
            let hook = admission(paneId: pane.id, signal: .turnStart)
            switch mode {
            case .unbound: break
            case .live, .ended:
                _ = try await ingestion.submitHook(hook)
                if mode == .ended {
                    _ = try await ingestion.submitHook(admission(paneId: pane.id, signal: .sessionEnd))
                }
            case .unverified:
                _ = try await ingestion.recordUnverifiedStatus(
                    paneId: pane.id, hook: hook,
                    refusal: .init(reason: .credentialNotRecognized, event: nil, at: .distantPast, intent: .status),
                    remainsPresent: { true })
            }
            let statuses = SessionStatusAtom()
            let mailbox = await ingestion.statusPublicationMailbox
            statuses.apply(mailbox.takeBatch())
            let readers = makePaneContextMetadataTestReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) },
                readSessionStatus: { try await ingestion.readSessionStatus(paneId: $0.uuid) })

            let identity = PaneManagementSessionIdentity()
            defer { identity.close() }
            await identity.refresh(paneId: pane.id, readers: readers)
            let session = identity.summary
            let context = PaneManagementContext.project(paneId: pane.id, store: store).includingVerifiedLiveSession(
                session)

            #expect(context.identityRows.first { $0.id == "pane" }?.text == pane.id.uuidString)
            let sessionRow = context.identityRows.first { $0.id == "session" }
            #expect(sessionRow?.text == (mode == .live ? "codex · provider-conversation" : nil))
            #expect(sessionRow?.toolTip == sessionRow?.text)
            if mode == .unverified {
                #expect(readers.sessionStatusForPane(paneId)?.status == .working(.active))
                #expect(try await ingestion.readSessionStatus(paneId: pane.id) == .unbound)
            }
        }
    }

    @Test("reopening reads the new session while Working paint stays equal and the binding changes")
    func reopeningReadsNewSessionAfterSwap() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.withIngestion { ingestion, _ in
            try await Self.checkReopening(ingestion: ingestion)
        }
    }

    private static func checkReopening(ingestion: SessionsIngestion) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Terminal")
            let paneId = PaneId(existingUUID: pane.id)
            _ = try await ingestion.submitHook(admission(paneId: pane.id, sessionId: "A", signal: .turnStart))
            let statuses = SessionStatusAtom()
            let mailbox = await ingestion.statusPublicationMailbox
            statuses.apply(mailbox.takeBatch())
            let before = statuses.value(for: paneId)
            var readCount = 0
            let readers = makePaneContextMetadataTestReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) },
                readSessionStatus: {
                    readCount += 1
                    return try await ingestion.readSessionStatus(paneId: $0.uuid)
                })
            let identity = PaneManagementSessionIdentity()
            defer { identity.close() }
            await identity.refresh(paneId: pane.id, readers: readers)
            #expect(identity.summary?.sessionRef.value == "A")

            _ = try await ingestion.submitHook(admission(paneId: pane.id, sessionId: "A", signal: .sessionEnd))
            _ = try await ingestion.submitHook(admission(paneId: pane.id, sessionId: "B", signal: .turnStart))
            statuses.apply(mailbox.takeBatch())
            let previous = try #require(before)
            let current = try #require(statuses.value(for: paneId))
            #expect(previous.status == .working(.active))
            #expect(current.status == previous.status)
            #expect(current.connectionIssue == previous.connectionIssue)
            #expect(current.evidence == previous.evidence)
            #expect(current.compactPrompt == previous.compactPrompt)
            #expect(current.promptListRevision == previous.promptListRevision)
            let previousBinding = try #require(previous.currentBindingId, "The initial live binding must be published")
            let currentBinding = try #require(
                current.currentBindingId, "The replacement live binding must be published")
            #expect(currentBinding != previousBinding, "D53 must expose the new current binding despite equal paint")

            identity.close()
            #expect(identity.summary == nil)
            await identity.refresh(paneId: pane.id, readers: readers)

            #expect(readCount == 2)
            #expect(identity.summary?.sessionRef.value == "B")
            let context = PaneManagementContext.project(paneId: pane.id, store: store).includingVerifiedLiveSession(
                identity.summary)
            #expect(context.identityRows.first { $0.id == "session" }?.text == "codex · B")
        }
    }

    @Test("the information card uses sidebar line order without the duplicate worktree line")
    func informationLinesMatchSidebar() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Terminal")
            store.paneAtom.updatePaneNote(pane.id, note: "Watch release logs")
            let paneId = PaneId(existingUUID: pane.id)
            let writer = AgentMessageSender.session(
                provider: try .init("codex"), sessionRef: try .init("provider-conversation"),
                bindingGeneration: UUIDv7.generate())
            let detail = AgentLineDetail(
                summary: "Checking changes", refs: [],
                writer: writer, updatedAt: .distantPast)
            atoms.paneContextPresentation.apply([
                paneId: .set(
                    .init(
                        revision: .init(1), agentTitle: "Agent title", agentLine: detail,
                        own: .zero, includingDrawers: .zero, pullRequests: .notApplicable))
            ])
            let statuses = SessionStatusAtom()
            statuses.apply([paneId: .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized))])
            let readers = makePaneContextMetadataTestReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) })
            let context = PaneManagementContext.project(paneId: pane.id, store: store)
            let input = PaneManagementIdentityCapture.input(context: context, store: store, readers: readers)

            let lines = await PaneManagementIdentityCapture.lines(input, now: .distantPast)

            #expect(lines.map(\.kind) == [.title, .note, .sessionStatus, .agentLine, .connectionIssue])
            #expect(lines.first == .title("Agent title"))
            #expect(lines[1] == .note("Watch release logs"))
            let sidebar = RepoExplorerPaneRowVariants.make(
                title: "Agent title",
                agentLine: detail,
                sessionPresentation: .init(status: .working(.active), evidence: .verifiedLive),
                now: .distantPast)
            #expect(
                lines.filter { $0.kind != .connectionIssue && $0.kind != .note }
                    == sidebar.expanded.lines.filter { $0.kind != .worktreeBranch })
            #expect(!sidebar.compact.lines.contains { $0.kind == .connectionIssue })
            #expect(lines.last == .connectionIssue(.connection(.credentialNotRecognized)))
            #expect(!context.identityRows.contains { $0.id == "note" })
        }
    }

    private static func admission(
        paneId: UUID, sessionId: String = "provider-conversation", signal: SessionProviderSignal
    ) -> SessionsHookAdmission {
        .init(
            paneId: paneId, providerIdentifier: "codex", providerVersion: "0.160.0",
            sessionId: sessionId, eventName: signal.name, turnId: nil, signal: signal,
            recordId: UUIDv7.generate(), admittedAt: .distantPast, chain: TestMainAgentChain.observation)
    }
}
