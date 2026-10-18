import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSessions
import Foundation

/// App captures keyed facts; the existing sidebar projection builds the display lines.
@MainActor
enum PaneManagementIdentityCapture {
    struct SessionRequest: Equatable {
        let paneId: UUID
        let presentation: PaneAgentStatusPresentation?
    }

    struct VerifiedIdentity {
        let request: SessionRequest
        let summary: SessionSummary?

        func session(for currentRequest: SessionRequest) -> SessionSummary? {
            request == currentRequest ? summary : nil
        }
    }

    struct LineInput: Equatable, Sendable {
        let paneId: UUID
        let title: String
        let note: String?
        let isDrawer: Bool
        let agentLine: AgentLineDetail?
        let sessionPresentation: PaneAgentStatusPresentation?
    }

    static func input(
        context: PaneManagementContext, store: WorkspaceStore, readers: PaneContextUIReaders?
    ) -> LineInput {
        let paneId = PaneId(existingUUID: context.paneId)
        return LineInput(
            paneId: context.paneId,
            title: readers?.titleForPane(paneId) ?? store.paneAtom.pane(context.paneId)?.title ?? "Terminal",
            note: atom(\.paneDisplay).displayParts(for: context.paneId).note,
            isDrawer: readers?.isDrawerPane(paneId) ?? false,
            agentLine: readers?.contextDisplayForPane(paneId)?.agentLine,
            sessionPresentation: readers?.sessionStatusForPane(paneId))
    }

    @concurrent nonisolated static func lines(_ input: LineInput) async -> [RepoExplorerPaneRowLine] {
        RepoExplorerPaneRowVariants.informationLines(
            title: input.title, note: input.note, agentLine: input.agentLine,
            sessionStatus: input.sessionPresentation?.status,
            connectionIssue: input.sessionPresentation?.connectionIssue)
    }

    static func verifiedLiveSession(paneId: UUID, readers: PaneContextUIReaders?) async -> SessionSummary? {
        guard let readers, let result = try? await readers.readSessionStatus(.init(existingUUID: paneId)),
            case .live(let summary) = result
        else { return nil }
        return summary
    }
}
