import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import Foundation

@testable import AgentStudio

enum PopoverReadFact: Sendable, Equatable {
    case started(PaneContextReadRequest)
    case finished
}
enum PopoverReleaseFact: Sendable, Equatable {
    case released
}

actor PaneContextPopoverTestPorts: PaneContextDetailReading, PaneContextPersonActing {
    let reads = FactRecorder<Int, PopoverReadFact>(
        vocabulary: .init(
            describeScope: { "read \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .finished }))
    let releases = FactRecorder<Int, PopoverReleaseFact>(
        vocabulary: .init(
            describeScope: { "release \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, _ in true }))
    private var results: [PaneContextReadResult]
    private var fallback: PaneContextDetail
    private let heldReads: Set<Int>
    private var readNumber = 0
    private(set) var requests: [PaneContextReadRequest] = []
    private(set) var answers: [AnswerAskRequest] = []
    private(set) var dismissals: [(AgentMessageId, PaneId)] = []
    private(set) var readsMarked: [(AgentMessageId, PaneId)] = []
    private(set) var actions: [MessageActionRequest] = []
    private var answerResults: [AnswerAskResult] = []
    var answerResult: AnswerAskResult = .answered
    var dismissResult: DismissResult = .done
    var markReadResult: MarkReadResult = .done
    var actionResult: MessageActionResult = .notFound
    init(_ detail: PaneContextDetail, results: [PaneContextReadResult] = [], heldReads: Set<Int> = []) {
        fallback = detail
        self.results = results
        self.heldReads = heldReads
    }
    func setDetail(_ detail: PaneContextDetail) { fallback = detail }
    func enqueue(_ result: PaneContextReadResult) { results.append(result) }
    func configureAnswers(_ results: [AnswerAskResult]) { answerResults = results }
    func configureAnswer(_ result: AnswerAskResult) { answerResult = result }
    func configureDismiss(_ result: DismissResult) { dismissResult = result }
    func configureMarkRead(_ result: MarkReadResult) { markReadResult = result }
    func configureAction(_ result: MessageActionResult) { actionResult = result }
    func release(_ number: Int) { releases.append(scope: number, fact: .released) }

    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        let number = readNumber
        readNumber += 1
        requests.append(request)
        let result = results.isEmpty ? .detail(fallback) : results.removeFirst()
        reads.append(scope: number, fact: .started(request))
        if heldReads.contains(number) {
            do { try await releases.expectNext(in: number, .released) } catch {
                reads.append(scope: number, fact: .finished)
                return .unavailable(.databaseUnavailable)
            }
        }
        reads.append(scope: number, fact: .finished)
        return result
    }
    func answer(_ request: AnswerAskRequest) async -> AnswerAskResult {
        answers.append(request)
        return answerResults.isEmpty ? answerResult : answerResults.removeFirst()
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
    func finish() async throws {
        try await reads.finish()
        try await releases.finish()
    }
}

@MainActor
func makePopoverController(
    ports: PaneContextPopoverTestPorts, location: PaneContextPopoverLocation = .pane,
    titleForPane: @escaping @MainActor (PaneId) -> String? = { _ in nil },
    revisionForPane: @escaping @MainActor (PaneId) -> PaneContextRevision? = { _ in nil }
) -> PaneContextPopoverController {
    PaneContextPopoverController(
        reader: ports, person: ports, location: location,
        titleForPane: titleForPane, revisionForPane: revisionForPane)
}
