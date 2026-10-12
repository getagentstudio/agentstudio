import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization

@testable import AgentStudioCore

enum ForgePublicationFact: Sendable {
    case output(ForgeEvent)
    case requestReturned(UInt64)
}

// Capture at the existing producer seam, before its unconditional bus post.
// The actual provider-task defer closes each request after owner post-processing.
final class ForgePublicationProbe: Sendable {
    private let observing = Mutex(false)
    private let recordedOutputs = Mutex<[ForgeEvent]>([])
    private let closingRequest: UInt64?
    private let source: LocalFactSource<UInt64, ForgePublicationFact>
    private let returns: LocalFactSource<UInt64, UInt64>
    let facts: FactRecorder<UInt64, ForgePublicationFact>
    let returnedFacts: FactRecorder<UInt64, UInt64>

    init(closingRequest: UInt64? = nil) throws {
        self.closingRequest = closingRequest
        let source = LocalFactSource(
            vocabulary: FactVocabulary<UInt64, ForgePublicationFact>(
                describeScope: { "forge operation \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .requestReturned(let request) = fact { return request == closingRequest }
                    return false
                }))
        self.source = source
        facts = try source.attach()
        let returns = LocalFactSource(
            vocabulary: FactVocabulary<UInt64, UInt64>(
                describeScope: { "forge request \($0)" }, describeFact: { "returned request \($0)" },
                isClosing: { scope, request in scope == request }))
        self.returns = returns
        returnedFacts = try returns.attach()
    }

    func begin() async -> OpeningPosition<UInt64> {
        let opening = await facts.mark(0)
        observing.withLock { $0 = true }
        return opening
    }

    func record(_ event: ForgeEvent) {
        guard observing.withLock({ $0 }) else { return }
        recordedOutputs.withLock { $0.append(event) }
        source.sink(0, .output(event))
    }

    func returned(_ request: UInt64) {
        returns.sink(request, request)
        guard request == closingRequest, observing.withLock({ $0 }) else { return }
        source.sink(0, .requestReturned(request))
        observing.withLock { $0 = false }
    }

    func expectReturn(_ request: UInt64) async throws {
        try await returnedFacts.expectNext(in: request, request)
    }

    var outputs: [ForgeEvent] { recordedOutputs.withLock { $0 } }

    func finish() async throws {
        try await facts.finish()
        try await returnedFacts.finish()
    }
}
