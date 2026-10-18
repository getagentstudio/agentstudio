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

            let session = await PaneManagementIdentityCapture.verifiedLiveSession(paneId: pane.id, readers: readers)
            let context = PaneManagementContext.project(paneId: pane.id, store: store).includingVerifiedLiveSession(
                session)

            #expect(context.identityRows.first { $0.id == "pane" }?.text == pane.id.uuidString)
            let sessionRow = context.identityRows.first { $0.id == "session" }
            #expect(sessionRow?.text == (mode == .live ? "codex · provider-conversation" : nil))
            #expect(sessionRow?.toolTip == sessionRow?.text)
            if mode == .live {
                let request = PaneManagementIdentityCapture.SessionRequest(
                    paneId: pane.id, presentation: readers.sessionStatusForPane(paneId))
                let captured = PaneManagementIdentityCapture.VerifiedIdentity(request: request, summary: session)
                let unverifiedRequest = PaneManagementIdentityCapture.SessionRequest(
                    paneId: pane.id,
                    presentation: .init(status: .working(.active), connectionIssue: .credentialNotRecognized))
                let changed = context.includingVerifiedLiveSession(captured.session(for: unverifiedRequest))
                #expect(!changed.identityRows.contains { $0.id == "session" })
                #expect(captured.session(for: request) == session)
            }
            if mode == .unverified {
                #expect(readers.sessionStatusForPane(paneId)?.status == .working(.active))
                #expect(try await ingestion.readSessionStatus(paneId: pane.id) == .unbound)
            }
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
                summary: "Checking changes", work: .monitoring("checks"), detail: nil, refs: [],
                writer: writer, updatedAt: .distantPast, lifetime: .untilReplaced, stale: false)
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

            let lines = await PaneManagementIdentityCapture.lines(input)

            #expect(lines.map(\.kind) == [.title, .note, .agentLine, .sessionStatus, .connectionIssue])
            #expect(lines.first == .title("Agent title"))
            #expect(lines[1] == .note("Watch release logs"))
            let sidebar = RepoExplorerPaneRowVariants.make(
                title: "Agent title", branchContext: "repo · main", note: "Watch release logs",
                isDrawer: false, branchStatus: nil, isActive: false, agentLine: detail,
                sessionStatus: .working(.active), connectionIssue: .credentialNotRecognized)
            #expect(lines == sidebar.expanded.lines.filter { $0.kind != .worktreeBranch })
            #expect(!context.identityRows.contains { $0.id == "note" })
        }
    }

    private static func admission(paneId: UUID, signal: SessionProviderSignal) -> SessionsHookAdmission {
        .init(
            paneId: paneId, providerIdentifier: "codex", providerVersion: "0.160.0",
            sessionId: "provider-conversation", eventName: signal.name, turnId: nil, signal: signal,
            recordId: UUIDv7.generate(), admittedAt: .distantPast)
    }
}
