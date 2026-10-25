import AgentStudioCore
import AgentStudioSessions
import AgentStudioSharedComponents
import Foundation

struct PaneContextRefreshKey: Equatable, Sendable {
    struct Source: Hashable, Sendable {
        let paneId: PaneId
        let promptListRevision: UInt64
    }
    let displayRevision: PaneContextRevision?
    let sources: [Source]
}

/// App composes Feature-owned keyed facts; consumers never reach across Features.
@MainActor
struct PaneContextUIReaders {
    let sessionStatusForPane: @MainActor (PaneId) -> PaneAgentStatusPresentation?
    let contextDisplayForPane: @MainActor (PaneId) -> PaneContextDisplay?
    let serviceProvider: @MainActor () -> PaneContextUIAdapter?
    let isDrawerPane: @MainActor (PaneId) -> Bool
    let titleForPane: @MainActor (PaneId) -> String?
    let readSessionStatus: @MainActor (PaneId) async throws -> SessionsStatusReadResult
    let scopeForPane: @MainActor (PaneId) -> [PaneId]

    init(
        sessionStatus: SessionStatusAtom, presentation: PaneContextPresentationAtom,
        pane: @escaping @MainActor (PaneId) -> Pane?,
        serviceProvider: @escaping @MainActor () -> PaneContextUIAdapter? = { nil },
        readSessionStatus: @escaping @MainActor (PaneId) async throws -> SessionsStatusReadResult = { _ in .unbound }
    ) {
        self.serviceProvider = serviceProvider
        self.readSessionStatus = readSessionStatus
        isDrawerPane = { pane($0)?.parentPaneId != nil }
        scopeForPane = { owner in
            [owner] + (pane(owner)?.drawer?.paneIds ?? []).map { PaneId(existingUUID: $0) }
        }
        sessionStatusForPane = { sessionStatus.value(for: $0) }
        contextDisplayForPane = { presentation.value(for: $0) }
        let titles = PaneDisplayTitleDerived(presentation: presentation)
        titleForPane = { paneId in
            guard let pane = pane(paneId) else { return nil }
            return titles.title(for: paneId, fallbackTitle: pane.title)
        }
    }

    func refreshKey(for pane: PaneId) -> PaneContextRefreshKey {
        .init(
            displayRevision: contextDisplayForPane(pane)?.revision,
            sources: scopeForPane(pane).map {
                .init(paneId: $0, promptListRevision: sessionStatusForPane($0)?.promptListRevision ?? 0)
            })
    }

    func makePopoverController(
        reader: any PaneContextDetailReading, person: any PaneContextPersonActing,
        location: PaneContextPopoverLocation, includingDrawers: Bool = true,
        wallNow: @escaping @Sendable () -> Date = Date.init
    ) -> PaneContextPopoverController {
        PaneContextPopoverController(
            reader: reader, person: person,
            location: location, includingDrawers: includingDrawers, titleForPane: titleForPane,
            refreshKeyForPane: { refreshKey(for: $0) }, wallNow: wallNow)
    }
}
