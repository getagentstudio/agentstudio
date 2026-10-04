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
    private(set) var linkFeedback: String?
    let location: PaneContextPopoverLocation
    private var reader: any PaneContextDetailReading
    private var person: any PaneContextPersonActing
    private var membership: (any PaneLinkMembershipPort)?
    private let contributor: BridgeLinkContributor
    private let titleForPane: @MainActor (PaneId) -> String?
    private let revisionForPane: @MainActor (PaneId) -> PaneContextRevision?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var detail: PaneContextDetail?

    init(
        reader: any PaneContextDetailReading, person: any PaneContextPersonActing,
        membership: (any PaneLinkMembershipPort)?, contributor: BridgeLinkContributor,
        location: PaneContextPopoverLocation, titleForPane: @escaping @MainActor (PaneId) -> String?,
        revisionForPane: @escaping @MainActor (PaneId) -> PaneContextRevision?
    ) {
        self.reader = reader
        self.person = person
        self.membership = membership
        self.contributor = contributor
        self.location = location
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

    func useCurrentMembership(_ port: (any PaneLinkMembershipPort)?) {
        membership = port
    }

    func open(_ pane: PaneId) async {
        if paneId != pane {
            state = nil
            detail = nil
            actionFeedback = nil
            linkFeedback = nil
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
        linkFeedback = nil
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
        generation &+= 1
        let requestGeneration = generation
        guard var snapshot = detail else {
            actionFeedback = "No notices"
            await refresh()
            return
        }

        var feedback: [String] = []
        var dismissedNoticeIDs: Set<AgentMessageId> = []
        let initialDismissal = await PaneContextPopoverAnswerParsing.dismissNotices(
            detail: snapshot, excluding: dismissedNoticeIDs, person: person)
        appendNoticeFeedback(initialDismissal, to: &feedback, dismissedNoticeIDs: &dismissedNoticeIDs)

        while let truncation = snapshot.truncation {
            let page: PaneContextReadPage
            if let omitted = truncation.omitted.first {
                page = .more(source: omitted.source, after: omitted.next)
            } else if truncation.remainingLiveSources > 0, let after = truncation.nextSourcesAfter {
                page = .moreSources(after: after)
            } else {
                break
            }

            guard
                let pageRead = await readDismissalPage(
                    owner, page: page, previous: snapshot, generation: requestGeneration)
            else { return }
            snapshot = pageRead.snapshot
            if let newPage = pageRead.newPage {
                let pageDismissal = await PaneContextPopoverAnswerParsing.dismissNotices(
                    detail: newPage, excluding: dismissedNoticeIDs, person: person)
                appendNoticeFeedback(pageDismissal, to: &feedback, dismissedNoticeIDs: &dismissedNoticeIDs)
            }
        }

        guard paneId == owner, requestGeneration == generation else { return }
        actionFeedback = feedback.isEmpty ? "No notices" : feedback.joined(separator: "; ")
        await refresh()
    }

    private func appendNoticeFeedback(
        _ result: PaneContextPopoverNoticeDismissal, to feedback: inout [String],
        dismissedNoticeIDs: inout Set<AgentMessageId>
    ) {
        dismissedNoticeIDs.formUnion(result.noticeIDs)
        guard result.feedback != "No notices" else { return }
        feedback.append(result.feedback)
    }

    private struct DismissalPageRead: Sendable {
        let snapshot: PaneContextDetail
        let newPage: PaneContextDetail?
    }

    private func readDismissalPage(
        _ pane: PaneId, page: PaneContextReadPage, previous: PaneContextDetail,
        generation requestGeneration: UInt64
    ) async -> DismissalPageRead? {
        let result = await reader.readDetail(.init(paneId: pane, page: page))
        guard requestGeneration == generation, paneId == pane else { return nil }
        switch result {
        case .paneGone:
            close()
            return nil
        case .unavailable(let failure):
            let note = await PaneContextPopoverFeedback.unavailable(failure)
            guard requestGeneration == generation else { return nil }
            unavailableNote = "Context unavailable: \(note)"
            return nil
        case .sourceNotInView:
            let dropped = await PaneContextPopoverPaging.dropSource(from: previous, page: page)
            guard requestGeneration == generation else { return nil }
            guard let dropped else { return .init(snapshot: previous, newPage: nil) }
            await assign(dropped, generation: requestGeneration)
            return .init(snapshot: dropped, newPage: nil)
        case .detail(let next):
            let update = await PaneContextPopoverPaging.merge(previous: previous, next: next, page: page)
            guard requestGeneration == generation else { return nil }
            switch update {
            case .restartFirst:
                return await readDismissalPage(
                    pane, page: .first, previous: previous, generation: requestGeneration)
            case .detail(let snapshot):
                await assign(snapshot, generation: requestGeneration)
                return .init(snapshot: snapshot, newPage: next)
            }
        }
    }

    func removeMember(_ worktree: WorktreeId) async {
        guard let owner = paneId, let membership else { return }
        do {
            let result = try await membership.removeMember(
                receiver: owner, worktree: worktree, contributor: contributor)
            let feedback = await PaneContextPopoverFeedback.member(result)
            guard paneId == owner else { return }
            linkFeedback = feedback
            if case .pendingDraftSettlement(let operationId) = result {
                let settlement = try await membership.awaitPendingMemberRemoval(
                    receiver: owner, operationId: operationId)
                let settledFeedback = await PaneContextPopoverFeedback.settlement(settlement)
                guard paneId == owner else { return }
                linkFeedback = settledFeedback
            }
            await refresh()
        } catch {
            let feedback = await PaneContextPopoverFeedback.linkFailure(error)
            guard paneId == owner else { return }
            linkFeedback = feedback
        }
    }

    func removePullRequestReference(_ reference: ForgePullRequestIdentity) async {
        guard let owner = paneId, let membership else { return }
        do {
            let result = try await membership.removePullRequestReference(
                receiver: owner, reference: reference, contributor: contributor)
            let feedback = await PaneContextPopoverFeedback.reference(result)
            guard paneId == owner else { return }
            linkFeedback = feedback
            await refresh()
        } catch {
            let feedback = await PaneContextPopoverFeedback.linkFailure(error)
            guard paneId == owner else { return }
            linkFeedback = feedback
        }
    }
}
