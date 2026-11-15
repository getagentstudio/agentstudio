import Hummingbird
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge

extension BridgeDevelopmentLocatedAnnotationHTTPRoutingTests {
    @Test("TQ53 reader terminal reaches the held waiter before any stale PART", arguments: [false, true])
    func terminalFileReaderReleasesArrivalWait(readerThrows: Bool) async throws {
        let recorder = try HTTPMetadataFrameRecorder()
        if readerThrows {
            await recorder.fail(TQ53ReaderFailure())
        } else {
            try await recorder.finish(nil)
        }
        let application = Application(responder: Router().buildResponder())
        try await application.test(.router) { client in
            let step = TQ53TerminalStep<Int>("stale File PART before HTTP resnapshot")
            let reading = Task {
                try await step.run(
                    describeCompletion: { (snapshot: HTTPFileBatchSnapshot) in
                        "snapshot target=\(snapshot.targetRevision)"
                    },
                    operation: {
                        var retained = HTTPFileBatchRetainedState()
                        return try await nextHTTPFileBatchSnapshot(
                            client: client,
                            connection: .init(
                                bootstrap: .init(paneSessionId: "terminal-pane", workerInstanceId: "terminal-worker"),
                                capability: "test-capability"),
                            recorder: recorder, retainedState: &retained,
                            beforeResnapshot: { _, _ in try await step.arrive(1) })
                    })
            }
            // Join first: completion must publish an outcome even if the waiter
            // has not started yet. Require it before waiting so a regression fails.
            _ = await reading.result
            reading.cancel()
            defer { step.release() }
            try #require(step.hasArrived)
            await #expect {
                try await step.firstArrival()
            } throws: { error in
                if readerThrows { return error is TQ53ReaderFailure }
                if case HTTPAnnotationIntegrationError.metadataStreamEnded = error { return true }
                return false
            }
        }
    }

    @Test("TQ53 completion without arrival names the step and observed target")
    func fileReaderReturnWithoutArrivalIsNamed() async throws {
        let step = TQ53TerminalStep<Int>("stale File PART before HTTP resnapshot")
        let reading = Task {
            try await step.run(describeCompletion: { (target: Int) in "snapshot target=\(target)" }, operation: { 17 })
        }
        _ = await reading.result
        reading.cancel()
        defer { step.release() }
        try #require(step.hasArrived)
        await #expect {
            try await step.firstArrival()
        } throws: { error in
            String(describing: error)
                == "stale File PART before HTTP resnapshot: producer completed without arrival; observed snapshot target=17"
        }
    }

    @Test("TQ53 successful arrival holds the producer until released")
    func fileReaderArrivalRetainsHold() async throws {
        let step = TQ53TerminalStep<Int>("stale File PART before HTTP resnapshot")
        let reading = Task {
            try await step.run(
                describeCompletion: { (target: Int) in "snapshot target=\(target)" },
                operation: {
                    try await step.arrive(9)
                    return 17
                })
        }
        do {
            #expect(try await step.firstArrival() == 9)
            step.release()
            #expect(try await reading.value == 17)
            #expect(step.arrivalCount == 1)
        } catch {
            step.release()
            reading.cancel()
            _ = await reading.result
            throw error
        }
    }
}

private struct TQ53ReaderFailure: Error {}
