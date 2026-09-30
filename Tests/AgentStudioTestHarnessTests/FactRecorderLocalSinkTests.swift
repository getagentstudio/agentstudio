import AgentStudioTestHarness
import Testing

private enum LocalSinkFact: Sendable, Equatable {
    case ownerEmitted
}

@Suite("FactRecorder local sink")
struct FactRecorderLocalSinkTests {
    @Test("a local sink fact after end fails the scope and finish")
    func localSinkFactAfterSourceEnd() async throws {
        let source = makeSource()
        let recorder = try source.attach()
        source.end()

        source.sink("scope", .ownerEmitted)

        await #expect(throws: FactAfterSourceTerminated.self) {
            try await recorder.expectNext(in: "scope", .ownerEmitted)
        }
        await #expect(throws: FactAfterSourceTerminated.self) { try await recorder.finish() }
    }

    @Test("a local sink fact after cancellation fails the scope and finish")
    func localSinkFactAfterSourceCancellation() async throws {
        let source = makeSource()
        let recorder = try source.attach()
        source.cancel()

        source.sink("scope", .ownerEmitted)

        await #expect(throws: FactAfterSourceTerminated.self) {
            try await recorder.expectNext(in: "scope", .ownerEmitted)
        }
        await #expect(throws: FactAfterSourceTerminated.self) { try await recorder.finish() }
    }

    private func makeSource() -> LocalFactSource<String, LocalSinkFact> {
        LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { $0 },
                describeFact: { String(describing: $0) },
                isClosing: { _, _ in false }
            )
        )
    }
}
