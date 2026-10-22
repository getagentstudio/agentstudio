import AgentStudioCore
import AgentStudioSessions
import AgentStudioSharedComponents

/// App composes Feature-owned keyed facts; consumers never reach across Features.
@MainActor
struct PaneContextUIReaders {
    let sessionStatusForPane: @MainActor (PaneId) -> PaneAgentStatusPresentation?
    let contextDisplayForPane: @MainActor (PaneId) -> PaneContextDisplay?
    let serviceProvider: @MainActor () -> PaneContextUIAdapter?
    let isDrawerPane: @MainActor (PaneId) -> Bool
    let titleForPane: @MainActor (PaneId) -> String?
    let readSessionStatus: @MainActor (PaneId) async throws -> SessionsStatusReadResult

    init(
        sessionStatus: SessionStatusAtom, presentation: PaneContextPresentationAtom,
        pane: @escaping @MainActor (PaneId) -> Pane?,
        serviceProvider: @escaping @MainActor () -> PaneContextUIAdapter? = { nil },
        readSessionStatus: @escaping @MainActor (PaneId) async throws -> SessionsStatusReadResult = { _ in .unbound }
    ) {
        self.serviceProvider = serviceProvider
        self.readSessionStatus = readSessionStatus
        isDrawerPane = { pane($0)?.parentPaneId != nil }
        sessionStatusForPane = { sessionStatus.value(for: $0) }
        contextDisplayForPane = { presentation.value(for: $0) }
        let titles = PaneDisplayTitleDerived(presentation: presentation)
        titleForPane = { paneId in
            guard let pane = pane(paneId) else { return nil }
            return titles.title(for: paneId, fallbackTitle: pane.title)
        }
    }

    func makePopoverController(
        reader: any PaneContextDetailReading, person: any PaneContextPersonActing,
        location: PaneContextPopoverLocation, includingDrawers: Bool = true
    ) -> PaneContextPopoverController {
        PaneContextPopoverController(
            reader: reader, person: person,
            location: location, includingDrawers: includingDrawers, titleForPane: titleForPane,
            revisionForPane: { contextDisplayForPane($0)?.revision })
    }
}
