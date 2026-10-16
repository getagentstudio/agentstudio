import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Provider hook status fallback budget")
struct ProviderHookStatusFallbackTests {
    @Test(
        "input, rejected login and status delivery keep one absolute expiration",
        arguments: [CodexHookEventName.stop, .sessionEnd], [false, true])
    func rejectedLoginSharesExpiration(event: CodexHookEventName, exhaustLogin: Bool) throws {
        let timing = StatusFallbackTiming()
        let limit: Duration = event == .sessionEnd ? .milliseconds(250) : .seconds(2)
        let deadline = CallDeadline(limit: limit, timing: timing)
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let payload = try CodexFixtures.data(for: event)
        let reports = Mutex<[IPCSessionStatusParams]>([])
        let fallbackBudgets = Mutex<[Duration]>([])
        let diagnostics = Mutex<[String]>([])
        let loginCost: Duration = exhaustLogin ? limit - .milliseconds(100) : .milliseconds(50)
        let delivery = ProviderHookDelivery(
            deliver: { _, _, authenticationDeadline in
                #expect(authenticationDeadline.remainingBudget == limit - .milliseconds(100))
                timing.advance(by: loginCost)
                throw IPCDescriptorClientFailure(disposition: .authenticationRejected, reason: .authenticationResponse)
            },
            recordRefusal: { _, _, _ in Issue.record("Valid payload must not report a refusal") },
            reportStatus: { params, configuration, fallbackDeadline in
                #expect(configuration.authToken == nil)
                reports.withLock { $0.append(params) }
                fallbackBudgets.withLock { $0.append(fallbackDeadline.remainingBudget) }
                timing.advance(by: limit - .milliseconds(150))
                #expect(fallbackDeadline.remainingBudget == .zero)
            })
        let exitCode = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: event.rawValue,
                environment: [
                    "AGENTSTUDIO_PANE_TOKEN": "refused-fixture-token", "AGENTSTUDIO_IPC_SOCKET": "/fixture/socket",
                    "AGENTSTUDIO_PANE_ID": paneID.uuidString, "AGENTSTUDIO_WORKSPACE_ID": workspaceID.uuidString,
                ],
                standardInput: {
                    timing.advance(by: .milliseconds(100))
                    return payload
                },
                correlationIdProvider: { UUIDv7.generate() }, delivery: delivery,
                standardErrorSink: { label in diagnostics.withLock { $0.append(label) } }, deadline: deadline))
        #expect(exitCode == 0)
        #expect(deadline.remainingBudget == .zero)
        #expect(timing.elapsed == limit)
        let statuses = reports.withLock { $0 }
        if exhaustLogin {
            #expect(statuses.isEmpty)
            #expect(fallbackBudgets.withLock { $0.isEmpty })
            #expect(diagnostics.withLock { $0 } == ["credentialNotRecognized", "deadlineExceeded"])
        } else {
            #expect(statuses.count == 1)
            #expect(statuses.first?.paneClaim == .init(paneId: paneID, workspaceId: workspaceID))
            #expect(statuses.first?.tokenOutcome == .rejected)
            #expect(fallbackBudgets.withLock { $0 } == [limit - .milliseconds(150)])
            #expect(diagnostics.withLock { $0 } == ["credentialNotRecognized"])
        }
    }

    @Test(
        "compiled status methods retain claim refusal reasons through real remote-error decoding",
        arguments: ["session.status", "pane.title.set", "pane.line.set", "pane.writer.claimEpoch"],
        [IPCAgentConnectionRefusalReason.paneNotFound, .paneRetired, .otherWorkspace, .intentRequiresToken])
    func claimRefusalKeepsDiagnosticReason(method: String, reason: IPCAgentConnectionRefusalReason) async throws {
        let observed = try await valueFromDedicatedThread { () throws -> ClaimRefusalObservation in
            let descriptors = try IPCCompiledInvocationResolver().resolve(
                arguments: [method], authenticated: false,
                inputs: .init(examples: .init(illustrativeIdentifier: UUIDv7.generate())))
            guard let descriptor = descriptors.first(where: { $0.metadata.name == method }),
                let sample = descriptor.metadata.examples.first
            else { return .missingCompiledExample }
            let invocation = try IPCDescriptorInvocation(
                descriptor: descriptor,
                normalizedParameters: descriptor.normalizeParameters(sample.encodedParameters()), presentation: .tooling
            )
            let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
            let listener = UnixSocketListener(endpoint: endpoint)
            try listener.start { connection in
                defer { connection.close() }
                var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
                let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
                try connection.send(
                    makeIPCDescriptorClientErrorFrame(
                        id: request.id, code: -32_001, message: "unauthenticated",
                        data: .object(["reason": .string(reason.rawValue)])))
            }
            defer { listener.stop() }
            let client = AgentStudioIPCClient(configuration: .init(socketPath: endpoint.path), descriptors: descriptors)
            guard case .remoteFailure(let failure) = try client.call(invocation) else { return .notRefused }
            let deadline = CallDeadline(limit: .seconds(2), timing: StatusFallbackTiming())
            return .refused(
                code: failure.code, documentedReason: failure.documentedReason,
                classifiedReason: ProviderHookStatusReporting.reason(for: failure, deadline: deadline))
        }
        #expect(
            observed == .refused(code: -32_001, documentedReason: reason.rawValue, classifiedReason: reason))
    }

    @Test("authentication transport failure grants no status fallback")
    func authenticationTransportFailureIsFinal() throws {
        let timing = StatusFallbackTiming()
        let diagnostics = Mutex<[String]>([])
        let payload = try CodexFixtures.data(for: .stop)
        let exitCode = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: "Stop",
                environment: [
                    "AGENTSTUDIO_PANE_TOKEN": "fixture-token", "AGENTSTUDIO_IPC_SOCKET": "/fixture/socket",
                    "AGENTSTUDIO_PANE_ID": UUIDv7.generate().uuidString,
                    "AGENTSTUDIO_WORKSPACE_ID": UUIDv7.generate().uuidString,
                ],
                standardInput: { payload }, correlationIdProvider: { UUIDv7.generate() },
                delivery: .init(
                    deliver: { _, _, _ in
                        throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .authenticationTransport)
                    },
                    recordRefusal: { _, _, _ in Issue.record("Unexpected refusal request") },
                    reportStatus: { _, _, _ in Issue.record("Transport failure must not reconnect for fallback") }),
                standardErrorSink: { label in diagnostics.withLock { $0.append(label) } },
                deadline: CallDeadline(limit: .seconds(2), timing: timing)))
        #expect(exitCode == 0)
        #expect(diagnostics.withLock { $0 } == ["appUnavailable"])
    }
}

private final class StatusFallbackTiming: CallDeadlineTiming, Sendable {
    private let origin = ContinuousClock.now
    private let elapsedTime = Mutex<Duration>(.zero)
    var elapsed: Duration { elapsedTime.withLock { $0 } }
    func now() -> ContinuousClock.Instant { origin.advanced(by: elapsed) }
    func advance(by duration: Duration) { elapsedTime.withLock { $0 += duration } }
    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) -> CallDeadlineReadiness {
        Issue.record("Delivery seam must not perform socket I/O")
        return .timedOut
    }
}

/// What a claim-refused compiled call observed on the dedicated thread, asserted on the test task.
private enum ClaimRefusalObservation: Equatable, Sendable {
    case missingCompiledExample
    case notRefused
    case refused(code: Int, documentedReason: String?, classifiedReason: IPCAgentConnectionRefusalReason)
}
