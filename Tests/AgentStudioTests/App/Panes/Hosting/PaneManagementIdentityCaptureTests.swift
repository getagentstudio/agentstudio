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
                    RepoExplorerPaneTitleNormalizer.normalizedTitle(
                        liveTitle: liveTitle, cwd: input.cwd, shellExecutablePath: "/bin/zsh")))
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
            let readers = PaneContextUIReaders(
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

    @Test("reopening reads the new session after equal Working publications coalesce")
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
            let readers = PaneContextUIReaders(
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
            #expect(statuses.value(for: paneId) == before)

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
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) })
            let context = PaneManagementContext.project(paneId: pane.id, store: store)
            let input = PaneManagementIdentityCapture.input(context: context, store: store, readers: readers)

            let lines = await PaneManagementIdentityCapture.lines(input, now: .distantPast)

            #expect(lines.map(\.kind) == [.title, .note, .agentLine, .sessionStatus, .connectionIssue])
            #expect(lines.first == .title("Agent title"))
            #expect(lines[1] == .note("Watch release logs"))
            let sidebar = RepoExplorerPaneRowVariants.make(
                title: "Agent title", branchContext: "repo · main", note: "Watch release logs",
                isDrawer: false, branchStatus: nil, isActive: false, agentLine: detail,
                sessionStatus: .working(.active), connectionIssue: .credentialNotRecognized, now: .distantPast)
            #expect(lines == sidebar.expanded.lines.filter { $0.kind != .worktreeBranch })
            #expect(!context.identityRows.contains { $0.id == "note" })
        }
    }

    private static func admission(
        paneId: UUID, sessionId: String = "provider-conversation", signal: SessionProviderSignal
    ) -> SessionsHookAdmission {
        .init(
            paneId: paneId, providerIdentifier: "codex", providerVersion: "0.160.0",
            sessionId: sessionId, eventName: signal.name, turnId: nil, signal: signal,
            recordId: UUIDv7.generate(), admittedAt: .distantPast)
    }
}
