import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Lifecycle queue policy from SR11b")
struct ProviderLifecyclePolicyTests {
    @Test(arguments: LifecycleDeliveryOutcome.allCases, LifecycleDeliveryRoute.allCases)
    func onlyNeverReachedEligibleEventsQueue(outcome: LifecycleDeliveryOutcome, route: LifecycleDeliveryRoute) throws {
        for provider in ["claude-code", "codex", "cursor"] {
            for event in [IPCSessionEventName.sessionStart, .sessionEnd, .turnStart] {
                let params = lifecyclePolicyParams(provider: provider, event: event)
                let queued = Mutex<[IPCSessionEventParams]>([])
                let capturedAt = Date(timeIntervalSince1970: 1.0006)
                let deadline = CallDeadline(limit: .seconds(2), timing: LifecycleDeadlineTiming())
                let reporting = ProviderHookStatusReporting(
                    environment: [
                        "AGENTSTUDIO_PANE_ID": UUIDv7.generate().uuidString,
                        "AGENTSTUDIO_WORKSPACE_ID": UUIDv7.generate().uuidString,
                    ],
                    configuration: .init(socketPath: "/unused", authToken: route == .claim ? nil : "fixture-token"),
                    delivery: .init(
                        deliver: { _, _, _ in
                            if route == .rejectedToken {
                                throw IPCDescriptorClientFailure(
                                    disposition: .authenticationRejected, reason: .authenticationResponse)
                            }
                            try outcome.deliver()
                        },
                        recordRefusal: { _, _, _ in try outcome.deliver() },
                        reportStatus: { _, _, _ in try outcome.deliver() }),
                    deadline: deadline, diagnosticSink: { _ in },
                    lifecycleWriter: .init { recorded, time, writeDeadline in
                        #expect(time == capturedAt)
                        #expect(writeDeadline.remainingBudget > .zero)
                        queued.withLock { $0.append(recorded) }
                    })
                reporting.event(params, reportedAt: capturedAt)
                let eligible = provider != "cursor" && event != .turnStart
                #expect(queued.withLock { $0 } == (eligible && outcome.mustQueue ? [params] : []))
            }
        }
    }

    @Test("refusals never become lifecycle rows")
    func refusalsNeverQueue() {
        let queued = Mutex(0)
        let reporting = ProviderHookStatusReporting(
            environment: [:], configuration: .init(socketPath: "/unused", authToken: "fixture-token"),
            delivery: .init(
                deliver: { _, _, _ in },
                recordRefusal: { _, _, _ in
                    throw IPCDescriptorClientFailure(
                        disposition: .endpointUnavailableBeforeSubmission, reason: .socketNotFound)
                }, reportStatus: { _, _, _ in }),
            deadline: CallDeadline(limit: .seconds(2), timing: LifecycleDeadlineTiming()), diagnosticSink: { _ in },
            lifecycleWriter: .init { _, _, _ in queued.withLock { $0 += 1 } })
        reporting.refusal(
            .init(handle: "self", reason: .noSessionId, event: "SessionEnd", correlationId: UUIDv7.generate()))
        #expect(queued.withLock { $0 } == 0)
    }
}

enum LifecycleDeliveryRoute: CaseIterable, Sendable { case token, claim, rejectedToken }

enum LifecycleDeliveryOutcome: CaseIterable, Sendable {
    case success, uncertain, remoteRefusal, endpointUnavailable, socketNotFound, connectFailure
    case authenticationTransport, commandWrite, localEncoding, authenticationRejected

    // Literal admission rule from SR11b / PD6, independent of permitsOfflineQueue.
    var mustQueue: Bool {
        switch self {
        case .endpointUnavailable, .socketNotFound, .connectFailure, .authenticationTransport, .commandWrite: true
        case .success, .uncertain, .remoteRefusal, .localEncoding, .authenticationRejected: false
        }
    }

    func deliver() throws {
        switch self {
        case .success: return
        case .uncertain:
            throw IPCDescriptorClientFailure(disposition: .deliveryUncertain, reason: .commandResponseMissing)
        case .remoteRefusal: throw ProviderHookFailure.rejected("queueFull")
        case .endpointUnavailable:
            throw IPCDescriptorClientFailure(disposition: .endpointUnavailableBeforeSubmission, reason: .socketNotFound)
        case .socketNotFound: throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .socketNotFound)
        case .connectFailure:
            throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .endpointConnectFailed(errnoCode: 61))
        case .authenticationTransport:
            throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .authenticationTransport)
        case .commandWrite: throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .commandWrite)
        case .localEncoding: throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .localRequestEncoding)
        case .authenticationRejected:
            throw IPCDescriptorClientFailure(disposition: .authenticationRejected, reason: .authenticationResponse)
        }
    }
}

func lifecyclePolicyParams(provider: String, event: IPCSessionEventName) -> IPCSessionEventParams {
    .init(
        handle: "self", provider: .init(identifier: provider, version: "1.0", mode: "interactive"),
        event: .init(
            name: event, conversationId: UUIDv7.generate().uuidString, turnId: nil, requestId: nil,
            toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()), correlationId: UUIDv7.generate())
}
