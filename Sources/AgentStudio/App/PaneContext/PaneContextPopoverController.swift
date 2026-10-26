import AgentStudioCore
import AgentStudioSharedComponents
import Foundation
import Observation

/// Host-owned UI state. Reads, action effects and shaping stay behind awaited seams.
@MainActor
@Observable
final class PaneContextPopoverController {
    private(set) var paneId: PaneId?
    private(set) var state: PaneContextPopoverShape?
    private(set) var unavailableNote: String?
    private(set) var actionFeedback: String?
    private(set) var selectedAsk: PaneContextSelectedAsk?
    let location: PaneContextPopoverLocation
    let includingDrawers: Bool
    private var reader: any PaneContextDetailReading
    private var person: any PaneContextPersonActing
    private let titleForPane: @MainActor (PaneId) -> String?
    private let refreshKeyForPane: @MainActor (PaneId) -> PaneContextRefreshKey
    private let wallNow: @Sendable () -> Date
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var detail: PaneContextDetail?
    @ObservationIgnored private var readKey: PaneContextRefreshKey?
    @ObservationIgnored private var cardSelection: CardRequestSelection = .none
    @ObservationIgnored private var focusedMessage: PaneContextMessageKey?

    private var actionSnapshot: PaneContextActionSnapshot {
        switch location {
        case .card: .selectedAsk(selectedAsk)
        case .sidebar, .pane: .messages(detail)
        }
    }

    init(
        reader: any PaneContextDetailReading, person: any PaneContextPersonActing,
        location: PaneContextPopoverLocation, includingDrawers: Bool = true,
        titleForPane: @escaping @MainActor (PaneId) -> String?,
        refreshKeyForPane: @escaping @MainActor (PaneId) -> PaneContextRefreshKey,
        wallNow: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.person = person
        self.location = location
        self.includingDrawers = includingDrawers
        self.titleForPane = titleForPane
        self.refreshKeyForPane = refreshKeyForPane
        self.wallNow = wallNow
    }

    func useCurrentService(_ adapter: PaneContextUIAdapter?) -> Bool {
        guard let adapter else {
            generation &+= 1
            paneId = nil
            state = nil
            detail = nil
            selectedAsk = nil
            unavailableNote = "Not available right now"
            return false
        }
        reader = adapter
        person = adapter
        return true
    }

    func open(_ pane: PaneId) async {
        guard !Task.isCancelled else { return }
        if paneId != pane {
            state = nil
            detail = nil
            actionFeedback = nil
            unavailableNote = nil
        }
        paneId = pane
        await refresh()
    }

    func openCard(_ pane: PaneId, selection: CardRequestSelection) async {
        if cardSelection != selection { actionFeedback = nil }
        cardSelection = selection
        await open(pane)
    }

    func openMessages(_ pane: PaneId, focusedMessage: PaneContextMessageKey?) async {
        self.focusedMessage = focusedMessage
        await open(pane)
    }

    func close() {
        generation &+= 1
        paneId = nil
        state = nil
        detail = nil
        selectedAsk = nil
        cardSelection = .none
        focusedMessage = nil
        readKey = nil
        unavailableNote = nil
        actionFeedback = nil
    }

    func refresh() async {
        guard let paneId, !Task.isCancelled else { return }
        generation &+= 1
        let requestGeneration = generation
        if case .card = location { selectedAsk = nil }
        await read(paneId, page: .first, generation: requestGeneration)
        guard requestGeneration == generation, self.paneId == paneId, unavailableNote == nil else { return }
        if case .card = location {
            await readSelectedAsk(owner: paneId, generation: requestGeneration)
        } else if let focusedMessage {
            await readFocusedMessage(focusedMessage, owner: paneId, generation: requestGeneration)
        }
    }

    private func readFocusedMessage(_ key: PaneContextMessageKey, owner: PaneId, generation requestGeneration: UInt64)
        async
    {
        guard let detail, detail.scopedSessions.contains(where: { $0.sourcePaneId == key.paneId }) else { return }
        let result = await reader.readMessage(source: key.paneId, message: key.messageId)
        guard generation == requestGeneration, paneId == owner, focusedMessage == key else { return }
        switch result {
        case .found(let message):
            guard message.sourcePaneId == key.paneId, message.id == key.messageId else { return }
            let snapshot = await PaneContextFocusedMessageProjection.including(message, in: detail)
            await assign(snapshot, generation: requestGeneration)
        case .notFound: break
        case .unavailable(let failure):
            let note = await PaneContextPopoverFeedback.unavailable(failure)
            guard generation == requestGeneration else { return }
            unavailableNote = "Context unavailable: \(note)"
        }
    }

    private func readSelectedAsk(owner: PaneId, generation requestGeneration: UInt64) async {
        guard case .ask(let source, let message) = cardSelection else {
            selectedAsk = nil
            return
        }
        guard detail?.scopedSessions.contains(where: { $0.sourcePaneId == source }) == true else {
            selectedAsk = nil
            return
        }
        let selection = cardSelection
        let result = await reader.readMessage(source: source, message: message)
        guard !Task.isCancelled, requestGeneration == generation, paneId == owner, cardSelection == selection else {
            return
        }
        switch result {
        case .found(let found):
            guard found.id == message, found.sourcePaneId == source else {
                selectedAsk = nil
                return
            }
            selectedAsk = .init(
                key: .init(paneId: source, messageId: message), detail: found, generation: requestGeneration)
        case .notFound: selectedAsk = nil
        case .unavailable(let failure):
            let note = await PaneContextPopoverFeedback.unavailable(failure)
            guard requestGeneration == generation else { return }
            selectedAsk = nil
            unavailableNote = "Context unavailable: \(note)"
        }
    }

    /// The host observes the display and every scoped prompt-list revision.
    @discardableResult
    func refreshIfRevisionChanged() async -> Bool {
        guard let paneId, refreshKeyForPane(paneId) != readKey else { return false }
        await refresh()
        return true
    }

    func moreMessages(source: PaneId, after: LiveMessageCursor) async {
        guard let paneId else { return }
        generation &+= 1
        await read(paneId, page: .more(source: source, after: after), generation: generation)
    }

    func moreSources(after source: PaneId) async {
        guard let paneId else { return }
        generation &+= 1
        await read(paneId, page: .moreSources(after: source), generation: generation)
    }

    private func read(_ pane: PaneId, page: PaneContextReadPage, generation requestGeneration: UInt64) async {
        readKey = refreshKeyForPane(pane)
        let result = await reader.readDetail(.init(paneId: pane, page: page))
        guard requestGeneration == generation, paneId == pane else { return }
        switch result {
        case .paneGone:
            close()
        case .unavailable(let failure):
            let note = await PaneContextPopoverFeedback.unavailable(failure)
            guard requestGeneration == generation else { return }
            unavailableNote = "Context unavailable: \(note)"
        case .sourceNotInView:
            let dropped = await PaneContextPopoverPaging.dropSource(from: detail, page: page)
            guard requestGeneration == generation else { return }
            if let dropped { await assign(dropped, generation: requestGeneration) }
            await read(pane, page: .first, generation: requestGeneration)
        case .detail(let next):
            let update = await PaneContextPopoverPaging.merge(previous: detail, next: next, page: page)
            guard requestGeneration == generation else { return }
            switch update {
            case .restartFirst:
                await read(pane, page: .first, generation: requestGeneration)
            case .detail(let snapshot):
                await assign(snapshot, generation: requestGeneration)
            }
        }
    }

    private func assign(_ snapshot: PaneContextDetail, generation requestGeneration: UInt64) async {
        // These are keyed reads of canonical titles, not a join or projection.
        var titles: [PaneId: String] = [:]
        for source in snapshot.scopedSessions {
            titles[source.sourcePaneId] = titleForPane(source.sourcePaneId)
        }
        let shaped = await PaneContextPopoverShaping.shape(snapshot, sourceTitles: titles, now: wallNow())
        guard !Task.isCancelled, requestGeneration == generation, paneId == snapshot.paneId else { return }
        detail = snapshot
        state = shaped
        unavailableNote = nil
    }

    func answer(messageId: AgentMessageId, source: PaneId, value: AskAnswerValue) async {
        guard let owner = paneId else { return }
        let presentation = await PaneContextPopoverAnswerParsing.answerPresentation(
            messageId: messageId, source: source, snapshot: actionSnapshot, location: location)
        guard paneId == owner else { return }
        guard presentation == .inline else {
            actionFeedback = "Answer this ask in Messages"
            return
        }
        let result = await person.answer(.init(messageId: messageId, paneId: source, by: .localUser, value: value))
        let feedback = await PaneContextPopoverFeedback.answer(result, location: location)
        guard paneId == owner else { return }
        actionFeedback = feedback
        await refresh()
    }

    func answerDraft(messageId: AgentMessageId, source: PaneId, draft: AskFormDraft) async {
        guard let owner = paneId else { return }
        let answer = await PaneContextPopoverAnswerParsing.parse(
            messageId: messageId, source: source, snapshot: actionSnapshot, draft: draft)
        guard paneId == owner else { return }
        switch answer {
        case .success(let value):
            await self.answer(messageId: messageId, source: source, value: value)
        case .failure(let refusal):
            actionFeedback = await PaneContextPopoverFeedback.answer(.refused(refusal), location: location)
        }
    }

    func dismiss(messageId: AgentMessageId, source: PaneId) async {
        guard let owner = paneId else { return }
        let permitted = await PaneContextPopoverAnswerParsing.canDismiss(
            messageId: messageId, source: source, snapshot: actionSnapshot, location: location)
        guard paneId == owner else { return }
        guard permitted else {
            actionFeedback = "This message cannot be dismissed here"
            return
        }
        let result = await person.dismiss(messageId: messageId, paneId: source)
        let feedback = await PaneContextPopoverFeedback.dismiss(
            result, messageId: messageId, source: source, snapshot: actionSnapshot, location: location)
        guard paneId == owner else { return }
        actionFeedback = feedback
        await refresh()
    }

    func runAction(messageId: AgentMessageId, source: PaneId, action: MessageAction) async {
        guard let owner = paneId else { return }
        let permitted = await PaneContextPopoverAnswerParsing.canRunAction(
            messageId: messageId, source: source, snapshot: actionSnapshot, location: location)
        guard paneId == owner else { return }
        guard permitted else {
            actionFeedback = "This message action is not available here"
            return
        }
        let result = await person.runAction(.init(messageId: messageId, paneId: source, action: action))
        let feedback = await PaneContextPopoverFeedback.action(result)
        guard paneId == owner else { return }
        actionFeedback = feedback
        await refresh()
    }

    func dismissAllNotices() async {
        guard let owner = paneId else { return }
        let result = await person.dismissAllNotices(paneId: owner, includingDrawers: includingDrawers)
        guard paneId == owner else { return }
        actionFeedback = await PaneContextPopoverFeedback.dismissAll(result)
        await refresh()
    }

}
