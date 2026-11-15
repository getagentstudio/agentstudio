import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import Foundation

@testable import AgentStudio

enum PopoverReadFact: Sendable, Equatable {
    case started(PaneContextReadRequest)
    case finished
    case producerEndedWithoutRead
}
enum PopoverReleaseFact: Sendable, Equatable {
    case released
}
enum PopoverExactReadFact: Sendable, Equatable {
    case started(PaneId, AgentMessageId)
    case finished
    case producerEndedWithoutRead
}

enum PopoverAnswerFact: Sendable, Equatable {
    case recorded(AnswerAskRequest)
    case producerEndedWithoutAnswer
}

actor PaneContextPopoverTestPorts: PaneContextDetailReading, PaneContextPersonActing, PaneContextInvalidationReading {
    private let invalidationPort = PopoverOwnerInvalidationPorts()

    func invalidations(for sources: Set<PaneId>) async -> AsyncStream<PaneContextSourceInvalidation> {
        await invalidationPort.invalidations(for: sources)
    }
    func invalidationGenerations(for sources: Set<PaneId>) async -> [PaneId: UInt64] {
        await invalidationPort.invalidationGenerations(for: sources)
    }

    let answerFacts = FactRecorder<Int, PopoverAnswerFact>(
        vocabulary: .init(
            describeScope: { "person answer \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, _ in true }))
    let exactReads = FactRecorder<Int, PopoverExactReadFact>(
        vocabulary: .init(
            describeScope: { "exact read \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .finished || fact == .producerEndedWithoutRead }))
    let reads = FactRecorder<Int, PopoverReadFact>(
        vocabulary: .init(
            describeScope: { "read \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .finished || fact == .producerEndedWithoutRead }))
    let releases = FactRecorder<Int, PopoverReleaseFact>(
        vocabulary: .init(
            describeScope: { "release \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, _ in true }))
    private var results: [PaneContextReadResult]
    private var fallback: PaneContextDetail
    private let heldReads: Set<Int>
    private var heldReadSteps: [Int: HeldStep<Void>] = [:]
    private var readNumber = 0
    private var onDetailReadFact: (@Sendable (Int, PopoverReadFact) -> Void)?
    private var exactNumber = 0
    private var exactResults: [MessageReadResult] = []
    private var heldExactReads: Set<Int> = []
    private(set) var requests: [PaneContextReadRequest] = []
    private(set) var exactRequests: [PaneContextMessageKey] = []
    private(set) var answers: [AnswerAskRequest] = []
    private(set) var dismissals: [(AgentMessageId, PaneId)] = []
    private(set) var readsMarked: [(AgentMessageId, PaneId)] = []
    private(set) var actions: [MessageActionRequest] = []
    private(set) var dismissAllCalls: [(PaneId, Bool)] = []
    private var answerResults: [AnswerAskResult] = []
    var answerResult: AnswerAskResult = .answered
    var dismissResult: DismissResult = .done
    var markReadResult: MarkReadResult = .done
    var actionResult: MessageActionResult = .notFound
    var dismissAllResult: DismissAllNoticesResult = .dismissed(count: 0)
    init(_ detail: PaneContextDetail, results: [PaneContextReadResult] = [], heldReads: Set<Int> = []) {
        fallback = detail
        self.results = results
        self.heldReads = heldReads
    }
    func holdRead(_ number: Int, at step: HeldStep<Void>) { heldReadSteps[number] = step }
    func setDetail(_ detail: PaneContextDetail) { fallback = detail }
    func enqueue(_ result: PaneContextReadResult) { results.append(result) }
    func configureAnswers(_ results: [AnswerAskResult]) { answerResults = results }
    func configureAnswer(_ result: AnswerAskResult) { answerResult = result }
    func configureDismiss(_ result: DismissResult) { dismissResult = result }
    func configureMarkRead(_ result: MarkReadResult) { markReadResult = result }
    func configureAction(_ result: MessageActionResult) { actionResult = result }
    func configureDismissAll(_ result: DismissAllNoticesResult) { dismissAllResult = result }
    func configureExactReads(_ results: [MessageReadResult], held: Set<Int> = []) {
        exactResults = results
        heldExactReads = held
    }
    func releaseExact(_ number: Int) { releases.append(scope: 1000 + number, fact: .released) }
    func release(_ number: Int) { releases.append(scope: number, fact: .released) }

    func observeDetailReadFacts(_ observer: @escaping @Sendable (Int, PopoverReadFact) -> Void) {
        onDetailReadFact = observer
    }

    private func recordDetailRead(_ number: Int, _ fact: PopoverReadFact) {
        reads.append(scope: number, fact: fact)
        onDetailReadFact?(number, fact)
    }

    func detailProducerEnded(beforeRead number: Int) {
        if readNumber <= number { recordDetailRead(number, .producerEndedWithoutRead) }
    }

    func exactProducerEnded(beforeRead number: Int) {
        if exactNumber <= number { exactReads.append(scope: number, fact: .producerEndedWithoutRead) }
    }

    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        let number = readNumber
        readNumber += 1
        requests.append(request)
        let result = results.isEmpty ? .detail(fallback) : results.removeFirst()
        recordDetailRead(number, .started(request))
        if let step = heldReadSteps.removeValue(forKey: number) {
            try? await step.arrive(())
        } else if heldReads.contains(number) {
            do { try await releases.expectNext(in: number, .released) } catch {
                recordDetailRead(number, .finished)
                return .unavailable(.databaseUnavailable)
            }
        }
        recordDetailRead(number, .finished)
        return result
    }
    func answer(_ request: AnswerAskRequest) async -> AnswerAskResult {
        let number = answers.count
        answers.append(request)
        answerFacts.append(scope: number, fact: .recorded(request))
        return answerResults.isEmpty ? answerResult : answerResults.removeFirst()
    }
    func answerProducerEnded(beforeAnswer number: Int) {
        if answers.count <= number { answerFacts.append(scope: number, fact: .producerEndedWithoutAnswer) }
    }
    func readMessage(source: PaneId, message: AgentMessageId) async -> MessageReadResult {
        exactRequests.append(.init(paneId: source, messageId: message))
        let number = exactNumber
        exactNumber += 1
        let rows = fallback.messages + fallback.drawerMessages.flatMap(\.messages)
        let result: MessageReadResult =
            exactResults.isEmpty
            ? rows.first(where: { $0.sourcePaneId == source && $0.id == message }).map { .found($0) } ?? .notFound
            : exactResults.removeFirst()
        exactReads.append(scope: number, fact: .started(source, message))
        if heldExactReads.contains(number) {
            do { try await releases.expectNext(in: 1000 + number, .released) } catch {
                exactReads.append(scope: number, fact: .finished)
                return .unavailable(.databaseUnavailable)
            }
        }
        exactReads.append(scope: number, fact: .finished)
        return result
    }
    func dismiss(messageId: AgentMessageId, paneId: PaneId) async -> DismissResult {
        dismissals.append((messageId, paneId))
        return dismissResult
    }
    func markRead(messageId: AgentMessageId, paneId: PaneId) async -> MarkReadResult {
        readsMarked.append((messageId, paneId))
        return markReadResult
    }
    func runAction(_ request: MessageActionRequest) async -> MessageActionResult {
        actions.append(request)
        return actionResult
    }
    func dismissAllNotices(paneId: PaneId, includingDrawers: Bool) async -> DismissAllNoticesResult {
        dismissAllCalls.append((paneId, includingDrawers))
        return dismissAllResult
    }
    func finish() async throws {
        await invalidationPort.finish()
        onDetailReadFact = nil
        try await reads.finish()
        try await releases.finish()
        try await exactReads.finish()
        try await answerFacts.finish()
    }
}
