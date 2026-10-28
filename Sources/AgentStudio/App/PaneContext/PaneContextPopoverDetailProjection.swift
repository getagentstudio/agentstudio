import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation

/// Pure detached-stage shaping; all service/configuration reads are already in the request.
enum PaneContextPopoverDetailProjection {
    nonisolated static func project(
        _ snapshot: PaneContextPopoverSnapshot, baseline: PopoverDetail? = nil,
        performance: PaneContextPopoverPerformance = .init(recorder: nil)
    )
        -> PopoverDetail
    {
        let publication = PaneContextPopoverPublication(
            id: UUIDv7.generate(), request: snapshot.identity)
        let failure: StorageFailureSummary?
        let loaded: PaneContextPopoverSnapshot.Loaded?
        switch snapshot.state {
        case .ready(let value):
            loaded = value
            failure = nil
        case .unavailable(let error, let value):
            loaded = value
            failure = error
        case .paneGone:
            return .init(
                publication: publication,
                content: .init(body: .paneGone, feedback: nil, width: snapshot.frozenWidth ?? 480))
        }
        let feedback =
            failure.map { unavailable($0, servicePresent: snapshot.capture.serviceEpoch != nil) }
            ?? snapshot.actionFeedback
        let width = snapshot.frozenWidth ?? Double(AppStyles.Components.PaneContext.messagesPopoverIdealWidth)
        let detail: PaneContextDetail?
        let selection: PaneContextPopoverSelectedAsk
        switch loaded {
        case .detail(let value, let selected)?:
            detail = value
            selection = selected
        case .compact?, nil:
            detail = nil
            selection = .none
        }
        let shape = detail.map { shape($0, snapshot: snapshot) }
        switch snapshot.demand.content {
        case .messages:
            guard let shape else { return note(feedback ?? "Loading…", width: width, publication: publication) }
            let refreshed = PaneContextPopoverShapingKernel.refresh(shape, content: .messages, now: snapshot.wallNow)
            let bodies = PaneContextPopoverShapingKernel.prepareBodyLayouts(
                refreshed.shape.messages, geometry: snapshot.bodyGeometry,
                baseline: baseline?.bodyMeasurements ?? [:], performance: performance, consumer: snapshot.identity.key)
            let scrollToken =
                baseline?.shape?.messages == refreshed.shape.messages
                ? baseline?.messageScrollToken ?? UUIDv7.generate() : UUIDv7.generate()
            return .init(
                publication: publication,
                content: .init(
                    body: .messages(bodies.model, refreshed.shape.messagesTarget), feedback: feedback,
                    width: width),
                shape: refreshed.shape, nextAgeBoundary: refreshed.nextChange, messageScrollToken: scrollToken,
                bodyMeasurements: bodies.measurements)
        case .agentLine:
            guard let shape else { return note(feedback ?? "Loading…", width: width, publication: publication) }
            let refreshed = PaneContextPopoverShapingKernel.refresh(shape, content: .agentLine, now: snapshot.wallNow)
            return .init(
                publication: publication,
                content: .init(body: .agentLine(refreshed.shape.agentLine), feedback: feedback, width: width),
                shape: refreshed.shape, nextAgeBoundary: refreshed.nextChange)
        case .toolbar: return toolbar(snapshot, width: width, publication: publication)
        case .card:
            return card(
                snapshot, shape: shape, selection: selection, feedback: feedback, width: width, publication: publication
            )
        }
    }

    private nonisolated static func shape(_ detail: PaneContextDetail, snapshot: PaneContextPopoverSnapshot)
        -> PaneContextPopoverShape
    {
        let owner = snapshot.capture.sources[snapshot.identity.key.paneId]
        let display = owner?.display
        let counts =
            snapshot.demand.includingDrawers && owner?.structuralFacts?.isDrawerChild != true
            ? display?.includingDrawers.kinds : display?.own.kinds
        let titles = snapshot.capture.sources.compactMapValues { $0.display?.agentTitle ?? $0.title }
        let target: PaneContextMessagesTarget
        if case .messages(let requested) = snapshot.demand.content { target = requested } else { target = .top }
        return PaneContextPopoverShapingKernel.shape(
            detail, sourceTitles: titles, counts: counts ?? .zero, messagesTarget: target, now: snapshot.wallNow)
    }

    private nonisolated static func toolbar(
        _ snapshot: PaneContextPopoverSnapshot, width: Double, publication: PaneContextPopoverPublication
    ) -> PopoverDetail {
        let owner = snapshot.capture.sources[snapshot.identity.key.paneId]
        let projected = ToolbarProjection.project(
            display: owner?.display, isDrawer: owner?.structuralFacts?.isDrawerChild == true, now: snapshot.wallNow)
        let lines: [RepoExplorerPaneRowLine]
        if case .agentLine = projected.item, let line = owner?.display?.agentLine {
            lines = [.agentLine(.agent(line, now: snapshot.wallNow))]
        } else {
            lines = []
        }
        let value = PaneManagementIdentityCapture.Presentation(lines: lines, toolbarItem: projected.item)
        return .init(
            publication: publication, content: .init(body: .toolbar(value), feedback: nil, width: width),
            toolbar: value,
            nextAgeBoundary: projected.nextChange)
    }

    private nonisolated static func card(
        _ snapshot: PaneContextPopoverSnapshot, shape: PaneContextPopoverShape?,
        selection: PaneContextPopoverSelectedAsk, feedback: String?, width: Double,
        publication: PaneContextPopoverPublication
    ) -> PopoverDetail {
        let readUnavailable: Bool
        if case .unavailable = snapshot.state { readUnavailable = true } else { readUnavailable = false }
        let ownerId = snapshot.identity.key.paneId
        let owner = snapshot.capture.sources[ownerId]
        let children = snapshot.demand.includingDrawers ? owner?.structuralFacts?.ownedDrawerPaneIDs ?? [] : []
        let sources = [ownerId] + children.map { PaneId(existingUUID: $0) }
        let selected: PaneContextSelectedAsk?
        let selectionFailure: StorageFailureSummary?
        switch selection {
        case .current(let value):
            selected = value
            selectionFailure = nil
        case .pendingRefresh(let key, let retained):
            selected = retained?.key == key ? retained : nil
            selectionFailure = nil
        case .unavailable(_, let error):
            selected = nil
            selectionFailure = error
        case .none, .notFound, .settled, .detached:
            selected = nil
            selectionFailure = nil
        }
        let display = owner?.display
        let isDrawer = owner?.structuralFacts?.isDrawerChild == true
        let input = PaneManagementIdentityCapture.LineInput(
            paneId: ownerId.uuid, terminalTitle: owner?.title ?? "Terminal", cwd: owner?.structuralFacts?.cwd,
            shellExecutablePath: snapshot.shellExecutablePath, agentTitle: display?.agentTitle, note: owner?.note,
            isDrawer: isDrawer, agentLine: display?.agentLine, sessionPresentation: owner?.session,
            activityTime: owner?.activity, contextDisplay: display,
            scopedPresentations: sources.map { .init(source: $0, presentation: snapshot.capture.sources[$0]?.session) },
            selectedAsk: selected,
            selectedSourceTitle: selected.flatMap {
                let source = snapshot.capture.sources[$0.key.paneId]
                return source?.display?.agentTitle ?? source?.title
            }, cardUnavailable: readUnavailable || selectionFailure != nil, detailMessages: shape?.messages)
        let title = PaneContextPresentationRules.displayTitle(
            raw: input.terminalTitle, agentTitle: input.agentTitle, cwd: input.cwd, shell: input.shellExecutablePath)
        let information = PaneManagementIdentityCapture.Presentation(
            lines: RepoExplorerPaneRowVariants.informationLines(
                title: title, note: input.note, agentLine: input.agentLine,
                sessionStatus: input.sessionPresentation?.status,
                connectionIssue: input.sessionPresentation?.connectionIssue, now: snapshot.wallNow))
        let model = CardProjection.shape(input, now: snapshot.wallNow, information: information)
        let sessionIdentity = snapshot.liveSession.map { "\($0.provider.value) · \($0.sessionRef.value)" }
        let rendered = PopoverDetail.CardContent(
            information: model.information, statusChip: model.statusChip, activityText: model.activityText,
            unreadCount: model.unreadCount, request: model.request, moreCount: model.moreCount,
            sessionIdentity: sessionIdentity, isDrawer: isDrawer)
        let dates = [
            input.activityTime.map {
                PaneContextPresentationRules.age(referenceDate: $0.wallTime, now: snapshot.wallNow).nextChange
            },
            input.agentLine.map { RepoExplorerPaneContextLine.nextMessageAgeChangeDate($0, now: snapshot.wallNow) },
            selected.flatMap { value -> Date? in
                guard case .ask = model.request else { return nil }
                return PaneContextPresentationRules.age(referenceDate: value.detail.sentAt, now: snapshot.wallNow)
                    .nextChange
            },
        ]
        let note = selectionFailure.map { unavailable($0, servicePresent: true) } ?? feedback
        return .init(
            publication: publication, content: .init(body: .card(rendered), feedback: note, width: width), shape: shape,
            card: model,
            selectedAsk: { if case .ask = model.request { selected } else { nil } }(),
            liveSession: snapshot.liveSession, nextAgeBoundary: dates.compactMap { $0 }.min())
    }

    private nonisolated static func note(
        _ text: String, width: Double, publication: PaneContextPopoverPublication
    ) -> PopoverDetail {
        .init(publication: publication, content: .init(body: .note(text), feedback: nil, width: width))
    }

    private nonisolated static func unavailable(_ failure: StorageFailureSummary, servicePresent: Bool) -> String {
        guard servicePresent else { return "Not available right now" }
        let detail: String
        switch failure {
        case .databaseUnavailable: detail = "database unavailable"
        case .commitFailed: detail = "commit failed"
        case .decodeFailed(let field): detail = "decode failed: \(field)"
        }
        return "Context unavailable: \(detail)"
    }
}
