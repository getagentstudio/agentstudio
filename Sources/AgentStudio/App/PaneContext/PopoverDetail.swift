import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation

/// Immutable rendered content and its scheduler receipt; metadata never decides UI equality.
final class PopoverDetail: Sendable {
    struct CardContent: Equatable, Sendable {
        let information: PaneManagementIdentityCapture.Presentation
        let statusChip: RepoExplorerPaneContextLine?
        let activityText: String?
        let unreadCount: Int
        let sessionIdentity: String?
        let isDrawer: Bool
    }
    enum Body: Equatable, Sendable {
        case messages(MessagesPopoverModel, PaneContextMessagesTarget)
        case agentLine(AgentLinePopoverModel?)
        case card(CardContent)
        case toolbar(PaneManagementIdentityCapture.Presentation)
        case note(String)
        case paneGone
    }
    struct Content: Equatable, Sendable {
        let body: Body
        let feedback: String?
        let width: Double
    }

    let publication: PaneContextPopoverPublication
    let messageScrollToken: UUID?
    let content: Content
    let shape: PaneContextPopoverShape?
    let card: CardModel?
    let toolbar: PaneManagementIdentityCapture.Presentation?
    let liveSession: SessionSummary?
    let metadata: PaneContextPopoverProjectionOutcome.Accepted
    let bodyMeasurements: [PaneContextTextBodyKey: PaneContextMessageBodyMeasurement]
    let interactions: PaneContextPopoverInteractionIndex

    var isDrawer: Bool {
        if case .card(let card) = content.body { return card.isDrawer }
        return false
    }

    init(
        publication: PaneContextPopoverPublication, content: Content, shape: PaneContextPopoverShape? = nil,
        card: CardModel? = nil,
        toolbar: PaneManagementIdentityCapture.Presentation? = nil,
        liveSession: SessionSummary? = nil, nextAgeBoundary: Date? = nil, messageScrollToken: UUID? = nil,
        bodyMeasurements: [PaneContextTextBodyKey: PaneContextMessageBodyMeasurement] = [:],
        interactions: PaneContextPopoverInteractionIndex = .empty
    ) {
        self.publication = publication
        self.messageScrollToken = messageScrollToken
        self.content = content
        self.shape = shape
        self.card = card
        self.toolbar = toolbar
        self.liveSession = liveSession
        self.bodyMeasurements = bodyMeasurements
        self.interactions = interactions
        metadata = .init(nextAgeBoundary: nextAgeBoundary, openingWidth: content.width)
    }
}
