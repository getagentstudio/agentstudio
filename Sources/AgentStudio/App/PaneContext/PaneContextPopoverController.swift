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
    let location: PaneContextPopoverLocation
    let includingDrawers: Bool
    private var reader: any PaneContextDetailReading
    private var person: any PaneContextPersonActing
    private let titleForPane: @MainActor (PaneId) -> String?
    private let revisionForPane: @MainActor (PaneId) -> PaneContextRevision?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var detail: PaneContextDetail?

    init(
        reader: any PaneContextDetailReading, person: any PaneContextPersonActing,
        location: PaneContextPopoverLocation, includingDrawers: Bool = true,
        titleForPane: @escaping @MainActor (PaneId) -> String?,
        revisionForPane: @escaping @MainActor (PaneId) -> PaneContextRevision?
    ) {
        self.reader = reader
        self.person = person
        self.location = location
        self.includingDrawers = includingDrawers
        self.titleForPane = titleForPane
        self.revisionForPane = revisionForPane
    }

    func useCurrentService(_ adapter: PaneContextUIAdapter?) -> Bool {
        guard let adapter else {
            generation &+= 1
            paneId = nil
            state = nil
            detail = nil
            unavailableNote = "Not available right now"
            return false
        }
        reader = adapter
        person = adapter
        return true
    }

    func open(_ pane: PaneId) async {
        if paneId != pane {
            state = nil
            detail = nil
            actionFeedback = nil
            unavailableNote = nil
        }
        paneId = pane
        await refresh()
    }

    func close() {
        generation &+= 1
        paneId = nil
        state = nil
        detail = nil
        unavailableNote = nil
        actionFeedback = nil
    }

    func refresh() async {
        guard let paneId else { return }
        generation &+= 1
        await read(paneId, page: .first, generation: generation)
    }

    /// Stage 2 invokes this from its existing keyed revision observation.
    func refreshIfRevisionChanged() async {
        guard let paneId, let revision = revisionForPane(paneId), revision != state?.revision else { return }
        await refresh()
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
        titles[snapshot.paneId] = titleForPane(snapshot.paneId)
        for group in snapshot.drawerMessages {
            titles[group.sourcePaneId] = titleForPane(group.sourcePaneId)
        }
        let shaped = await PaneContextPopoverShaping.shape(snapshot, sourceTitles: titles)
        guard requestGeneration == generation, paneId == snapshot.paneId else { return }
        detail = snapshot
        state = shaped
        unavailableNote = nil
    }

    func answer(messageId: AgentMessageId, source: PaneId, value: AskAnswerValue) async {
        guard let owner = paneId else { return }
        guard location == .pane else {
            actionFeedback = "Answer this ask in the pane"
            return
        }
        let result = await person.answer(.init(messageId: messageId, paneId: source, by: .localUser, value: value))
        let feedback = await PaneContextPopoverFeedback.answer(result)
        guard paneId == owner else { return }
        actionFeedback = feedback
        await refresh()
    }

    func answerDraft(messageId: AgentMessageId, source: PaneId, draft: AskFormDraft) async {
        guard let owner = paneId else { return }
        guard location == .pane else {
            actionFeedback = "Answer this ask in the pane"
            return
        }
        let answer = await PaneContextPopoverAnswerParsing.parse(messageId: messageId, detail: detail, draft: draft)
        guard paneId == owner else { return }
        switch answer {
        case .success(let value):
            await self.answer(messageId: messageId, source: source, value: value)
        case .failure(let refusal):
            actionFeedback = await PaneContextPopoverFeedback.answer(.refused(refusal))
        }
    }

    func dismiss(messageId: AgentMessageId, source: PaneId) async {
        guard let owner = paneId else { return }
        let permitted = await PaneContextPopoverAnswerParsing.canDismiss(
            messageId: messageId, detail: detail, location: location)
        guard paneId == owner else { return }
        guard permitted else {
            actionFeedback = "Dismiss this ask in the pane"
            return
        }
        let result = await person.dismiss(messageId: messageId, paneId: source)
        let feedback = await PaneContextPopoverFeedback.dismiss(result, messageId: messageId, detail: detail)
        guard paneId == owner else { return }
        actionFeedback = feedback
        await refresh()
    }

    func markRead(messageId: AgentMessageId, source: PaneId) async {
        guard let owner = paneId else { return }
        let result = await person.markRead(messageId: messageId, paneId: source)
        let feedback = await PaneContextPopoverFeedback.markRead(result)
        guard paneId == owner else { return }
        actionFeedback = feedback
        await refresh()
    }

    func runAction(messageId: AgentMessageId, source: PaneId, action: MessageAction) async {
        guard let owner = paneId else { return }
        guard location == .pane else {
            actionFeedback = "Run this message action in the pane"
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
