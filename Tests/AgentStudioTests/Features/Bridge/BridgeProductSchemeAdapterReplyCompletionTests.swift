import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

@Suite("Bridge product scheme WebKit reply completion")
struct BridgeProductSchemeAdapterReplyCompletionTests {
    @Test("a normal command completes through the WebKit reply contract")
    func normalCommandCompletesWithoutWebKitContractViolation() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let dispatchGate = HeldStep<Void>("normalWebKitConsumerBeforeDispatch")
        let routedReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: bridgeProductSchemeWorkerOpenBody()
            )
        )
        let consumer = WebKitFaithfulProductReplyConsumer()

        await consumer.start(stream: routedReply.stream, beforeFirstDispatch: dispatchGate)
        _ = try await dispatchGate.firstArrival()
        dispatchGate.release()
        await consumer.joinConsumerTask()
        await routedReply.routingTask.value

        #expect(await consumer.firstOutcomeKind == "response")
        #expect(await consumer.contractViolations.isEmpty)
        #expect((await harness.provider.snapshot).controlRequests.count == 1)
    }

    @Test("a stopped WebKit consumer never receives failure after admission revocation")
    func stoppedConsumerDoesNotReceiveRevokedReplyFailure() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let routingGate = HeldStep<Void>("webkitRouteBeforeAdmission", cancellation: .holdThroughCancellation)
        let dispatchGate = HeldStep<Void>("webkitConsumerBeforeDispatch", cancellation: .holdThroughCancellation)
        let routedReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: bridgeProductSchemeWorkerOpenBody()
            ),
            routingStartGate: routingGate
        )
        let consumer = WebKitFaithfulProductReplyConsumer()
        await consumer.start(stream: routedReply.stream, beforeFirstDispatch: dispatchGate)
        _ = try await routingGate.firstArrival()

        harness.adapter.productAdmissionGate.close()
        routingGate.release()
        _ = try await dispatchGate.firstArrival()
        #expect(await consumer.firstOutcomeKind == "response")
        await consumer.stop()
        dispatchGate.release()
        await consumer.joinConsumerTask()
        await routedReply.routingTask.value

        #expect(await consumer.contractViolations.isEmpty)
        #expect((await harness.provider.snapshot).controlRequests.isEmpty)
    }

    @Test("a newer File content epoch retires the older WebKit response cleanly")
    func floorRetirementCompletesOlderContentReply() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        #expect(try await harness.openSession().response?.statusCode == 200)
        let firstRequest = try bridgeProductFileContentRequest(
            identitySuffix: "floor-older",
            workerDerivationEpoch: 1
        )
        let newerRequest = try bridgeProductFileContentRequest(
            identitySuffix: "floor-newer",
            workerDerivationEpoch: 2
        )
        let responseGate = HeldStep<Void>("olderContentResponseDispatch")
        let postResponseGate = HeldStep<PostResponseOutcome>("olderContentPostResponseOutcome")
        let olderReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.contentRoute,
                capability: harness.capabilityHeader,
                body: try JSONEncoder().encode(firstRequest)
            )
        )
        let consumer = WebKitFaithfulProductReplyConsumer()
        await consumer.start(
            stream: olderReply.stream,
            beforeFirstDispatch: responseGate,
            beforeFirstPostResponseOutcome: postResponseGate
        )
        _ = try await responseGate.firstArrival()
        responseGate.release()
        let postResponseOutcome = try await postResponseGate.firstArrival()
        guard case .data = postResponseOutcome else {
            let responseStatus = await consumer.responseStatusCode
            let responseStatusDescription = responseStatus.map(String.init) ?? "unknown"
            let producerFailureReasons = (await harness.provider.snapshot).producerFailureReasons
            let issueMessage =
                "Expected older content's first post-response outcome to be data; "
                + "got \(postResponseOutcome) with HTTP status \(responseStatusDescription) "
                + "and producer failures \(producerFailureReasons)"
            Issue.record("\(issueMessage)")
            postResponseGate.release()
            await consumer.joinConsumerTask()
            await olderReply.routingTask.value
            return
        }
        #expect(await consumer.responseStatusCode == 200)

        let newerReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.contentRoute,
                capability: harness.capabilityHeader,
                body: try JSONEncoder().encode(newerRequest)
            )
        )
        var newerIterator = newerReply.stream.makeAsyncIterator()
        do {
            guard case .response = try #require(await newerIterator.next()) else {
                Issue.record("A newer content response did not advance the File floor")
                await tearDownOlderContentReply(
                    postResponseGate: postResponseGate,
                    consumer: consumer,
                    olderReply: olderReply,
                    newerReply: newerReply
                )
                return
            }
        } catch {
            await tearDownOlderContentReply(
                postResponseGate: postResponseGate,
                consumer: consumer,
                olderReply: olderReply,
                newerReply: newerReply
            )
            throw error
        }
        await olderReply.routingTask.value
        postResponseGate.release()
        await consumer.joinConsumerTask()
        newerReply.routingTask.cancel()
        await newerReply.routingTask.value

        #expect(await consumer.firstOutcomeKind == "response")
        #expect(await consumer.contractViolations.isEmpty)
        #expect((await harness.session.snapshot).workerDerivationEpochBySurface[.file] == 2)
    }

    @Test("a pre-response admission failure completes the live WebKit request")
    func containedFailureBeforeResponseCompletesWebKitRequest() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let routingGate = HeldStep<Void>("containedBeforeResponseRouting")
        let dispatchGate = HeldStep<Void>("containedBeforeResponseDispatch")
        let routedReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: bridgeProductSchemeWorkerOpenBody()
            ),
            routingStartGate: routingGate
        )
        let consumer = WebKitFaithfulProductReplyConsumer()
        await consumer.start(stream: routedReply.stream, beforeFirstDispatch: dispatchGate)
        _ = try await routingGate.firstArrival()

        harness.adapter.productAdmissionGate.close()
        routingGate.release()
        _ = try await dispatchGate.firstArrival()
        dispatchGate.release()
        await consumer.joinConsumerTask()
        await routedReply.routingTask.value

        #expect(await consumer.firstOutcomeKind == "response")
        #expect(await consumer.contractViolations.isEmpty)
        #expect((await harness.provider.snapshot).controlRequests.isEmpty)
    }

    @Test("a post-response producer failure finishes the WebKit request cleanly")
    func containedFailureAfterResponseCompletesWebKitRequest() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make(contentReturnsWithoutTerminal: true)
        #expect(try await harness.openSession().response?.statusCode == 200)
        let contentRequest = try bridgeProductFileContentRequest(
            identitySuffix: "contained-after-response",
            workerDerivationEpoch: 1
        )
        let responseGate = HeldStep<Void>("containedAfterResponseDispatch")
        let postResponseGate = HeldStep<PostResponseOutcome>("containedAfterResponsePostResponseOutcome")
        let routedReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.contentRoute,
                capability: harness.capabilityHeader,
                body: try JSONEncoder().encode(contentRequest)
            )
        )
        let consumer = WebKitFaithfulProductReplyConsumer()
        await consumer.start(
            stream: routedReply.stream,
            beforeFirstDispatch: responseGate,
            beforeFirstPostResponseOutcome: postResponseGate
        )
        _ = try await responseGate.firstArrival()
        responseGate.release()
        let postResponseOutcome = try await postResponseGate.firstArrival()
        guard case .data = postResponseOutcome else {
            let responseStatus = await consumer.responseStatusCode
            let responseStatusDescription = responseStatus.map(String.init) ?? "unknown"
            let producerFailureReasons = (await harness.provider.snapshot).producerFailureReasons
            let issueMessage =
                "Expected contained content's first post-response outcome to be data; "
                + "got \(postResponseOutcome) with HTTP status \(responseStatusDescription) "
                + "and producer failures \(producerFailureReasons)"
            Issue.record("\(issueMessage)")
            postResponseGate.release()
            await consumer.joinConsumerTask()
            await routedReply.routingTask.value
            return
        }
        #expect(await consumer.responseStatusCode == 200)

        await routedReply.routingTask.value

        let acknowledgement = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: try contentAcknowledgementBody(
                    for: contentRequest.admission,
                    contentSequence: 0
                )
            )
        )
        postResponseGate.release()
        await consumer.joinConsumerTask()

        #expect(acknowledgement.response?.statusCode == 404)
        let acknowledgementRefusal = try BridgeProductStrictJSON.decode(
            BridgeProductContentAcknowledgementRefusedResponse.self,
            from: acknowledgement.body
        )
        #expect(acknowledgementRefusal.reason == .unknownRead)
        #expect(await consumer.firstOutcomeKind == "response")
        #expect(await consumer.contractViolations.isEmpty)
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("product scheme replies throw only CancellationError into WebKit")
    func productSchemeReplyErrorShapeIsClosed() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let transportDirectory = projectRoot.appending(
            path: "Sources/AgentStudio/Features/Bridge/Transport"
        )
        let adapterFiles = try FileManager.default.contentsOfDirectory(
            at: transportDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("BridgeProductSchemeAdapter")
                && $0.pathExtension == "swift"
        }
        #expect(adapterFiles.count >= 2)
        let sourceFiles = adapterFiles + [transportDirectory.appending(path: "BridgeSchemeHandler+RPC.swift")]
        var throwingCallCount = 0
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let throwingLines = source.split(separator: "\n").filter { $0.contains("finish(throwing:") }
            throwingCallCount += throwingLines.count
            #expect(throwingLines.allSatisfy { $0.contains("CancellationError()") })
        }
        #expect(throwingCallCount > 0)
    }

}

private func tearDownOlderContentReply(
    postResponseGate: HeldStep<PostResponseOutcome>,
    consumer: WebKitFaithfulProductReplyConsumer,
    olderReply: BridgeProductSchemeReplyWithRoutingTask,
    newerReply: BridgeProductSchemeReplyWithRoutingTask
) async {
    postResponseGate.release()
    await consumer.joinConsumerTask()
    await olderReply.routingTask.value
    newerReply.routingTask.cancel()
    await newerReply.routingTask.value
}

/// Mirrors WebKit's guarded response/data/finish calls and its unguarded
/// generic-error callback, so a late non-cancellation error is observable.
private enum PostResponseOutcome: Sendable, CustomStringConvertible {
    case data
    case finish
    case error(type: String, message: String)
    case cancelled

    var description: String {
        switch self {
        case .data: "data"
        case .finish: "finish"
        case .error(let type, let message): "error(type: \(type), message: \(message))"
        case .cancelled: "cancelled"
        }
    }

    init?(streamResult: Result<URLSchemeTaskResult?, any Error>) {
        switch streamResult {
        case .success(.some(.response)):
            return nil
        case .success(.some(.data)):
            self = .data
        case .success(.none):
            self = .finish
        case .failure(let error) where error is CancellationError:
            self = .cancelled
        case .failure(let error):
            self = .error(
                type: String(reflecting: type(of: error)),
                message: String(describing: error)
            )
        @unknown default:
            self = .error(type: "URLSchemeTaskResult", message: "unknown result")
        }
    }
}

private actor WebKitFaithfulProductReplyConsumer {
    private var task: Task<Void, Never>?
    private var stopped = false
    private(set) var firstOutcomeKind: String?
    private(set) var contractViolations: [String] = []
    private(set) var responseStatusCode: Int?
    private var receivedResponse = false

    func start(
        stream: AsyncThrowingStream<URLSchemeTaskResult, any Error>,
        beforeFirstDispatch: HeldStep<Void>,
        beforeFirstPostResponseOutcome: HeldStep<PostResponseOutcome>? = nil
    ) {
        task = Task {
            await consume(
                stream: stream,
                beforeFirstDispatch: beforeFirstDispatch,
                beforeFirstPostResponseOutcome: beforeFirstPostResponseOutcome
            )
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    func joinConsumerTask() async { await task?.value }

    private func consume(
        stream: AsyncThrowingStream<URLSchemeTaskResult, any Error>,
        beforeFirstDispatch: HeldStep<Void>,
        beforeFirstPostResponseOutcome: HeldStep<PostResponseOutcome>?
    ) async {
        var iterator = stream.makeAsyncIterator()
        var isFirst = true
        var didRecordPostResponseOutcome = false
        while true {
            let outcome: Result<URLSchemeTaskResult?, any Error>
            do {
                outcome = .success(try await iterator.next())
            } catch {
                outcome = .failure(error)
            }
            if isFirst {
                switch outcome {
                case .success(.some(.response)): firstOutcomeKind = "response"
                case .success(.some(.data)): firstOutcomeKind = "data"
                case .success(.none): firstOutcomeKind = "finish"
                case .failure: firstOutcomeKind = "error"
                @unknown default: firstOutcomeKind = "unknown"
                }
                isFirst = false
                _ = try? await beforeFirstDispatch.arrive(())
            }
            if receivedResponse, !didRecordPostResponseOutcome,
                let postResponseOutcome = PostResponseOutcome(streamResult: outcome)
            {
                didRecordPostResponseOutcome = true
                if let beforeFirstPostResponseOutcome {
                    _ = try? await beforeFirstPostResponseOutcome.arrive(postResponseOutcome)
                }
            }
            switch outcome {
            case .success(.some(.response(let response))):
                do { try Task.checkCancellation() } catch { return }
                if stopped || receivedResponse { contractViolations.append("response after stop or duplicate") }
                responseStatusCode = (response as? HTTPURLResponse)?.statusCode
                receivedResponse = true
            case .success(.some(.data)):
                do { try Task.checkCancellation() } catch { return }
                if stopped || !receivedResponse { contractViolations.append("data after stop or before response") }
            case .success(.none):
                do { try Task.checkCancellation() } catch { return }
                if stopped || !receivedResponse { contractViolations.append("finish after stop or before response") }
                return
            case .failure(let error):
                if error is CancellationError { return }
                // WebKit's generic catch has no cancellation check.
                if stopped { contractViolations.append("didFailWithError after stop") }
                return
            @unknown default:
                return
            }
        }
    }
}
