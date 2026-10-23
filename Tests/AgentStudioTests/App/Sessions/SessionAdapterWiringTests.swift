import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions
@testable import AgentStudioTestSupport

@MainActor
@Suite("Session adapter chain wiring", .serialized)
struct SessionAdapterWiringTests {
    @Test(
        "real session registrations elect a direct chain and refuse a nested chain",
        arguments: MainEligibilityRoute.allCases, [false, true])
    func socketEligibility(route: MainEligibilityRoute, nested: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        let clientPID = getpid()
        let nativeVersion = await valueFromDedicatedThread { DarwinProcessChainFactsReader().pidVersion(of: clientPID) }
        let version = try #require(nativeVersion)
        let facts = ScriptedIPCProcessFacts(peerPID: clientPID, peerVersion: version, nested: nested)
        let leader = MainEligibilityTableLeaderReader(leader: facts.shell, sessionID: .generateUUIDv7())
        let harness = try await SessionsVerticalHarness.make(
            processChainReader: DarwinProcessChainReader(facts: facts, readLimit: 16), terminalLeaderReader: leader)
        do {
            let pane = harness.boundPaneId
            let event = adapterWiringEvent()
            let provider = IPCSessionProviderIdentity(identifier: "claude-code", version: "1", mode: "interactive")
            switch route {
            case .verified:
                let result = try await harness.sessionEvent(
                    params: .init(
                        handle: pane.uuidString, provider: provider, event: event, correlationId: UUIDv7.generate()))
                #expect(result.disposition == .admitted)
            case .claim:
                let params = IPCSessionStatusParams(
                    paneClaim: .init(paneId: pane, workspaceId: harness.commandHarness.store.identityAtom.workspaceId),
                    tokenOutcome: .absent,
                    report: .hook(event: event, provider: provider, providerSessionId: event.conversationId),
                    correlationId: UUIDv7.generate())
                let response = try await harness.response(
                    method: "session.status", params: JSONRPCCodec.encodeJSONValue(params),
                    authentication: .unauthenticated)
                #expect(response.error == nil)
                let value = try #require(response.result)
                let result = try JSONDecoder().decode(IPCSessionEventResult.self, from: JSONEncoder().encode(value))
                #expect(result.disposition == .admitted)
            }
            #expect(facts.versionReadCount == 2)
            let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
            let context = try await composition.ingestion.repository.statusContext(paneId: pane)
            let query = try await harness.sessionQuery(paneId: pane)
            let elected = route == .verified && !nested
            #expect(query.sourceHealth == (elected ? .live : .unbound))
            #expect(query.session?.conversationId == (elected ? event.conversationId : nil))
            #expect(context.bindings.count == (elected ? 1 : 0))
            #expect(context.evidence.count == (elected ? 1 : 0))
            let claimMain = await composition.ingestion.unverifiedStatusRuntime.panes[pane]?.main?.sessionId
            #expect(claimMain == (route == .claim && !nested ? event.conversationId : nil))
            await harness.tearDown()
        } catch {
            await harness.tearDown()
            throw error
        }
    }

    @Test(
        "both adapters observe synchronously before their admission clock and FIFO enqueue",
        arguments: MainEligibilityRoute.allCases)
    func adapterObservationBeforeEnqueue(route: MainEligibilityRoute) async throws {
        let result = try await driveAdapterObservation(route: route, refusalOnly: false)
        #expect(result.operations == [.observe, .clock, .enqueue])
        #expect(result.peers == [ProcessChainPeer(pid: 500, pidVersion: 17)])
        #expect(result.session == "wire-main")
    }

    @Test("refusal-only status takes no process observation")
    func refusalOnlyTakesNoObservation() async throws {
        let result = try await driveAdapterObservation(route: .claim, refusalOnly: true)
        #expect(result.operations == [.clock, .enqueue])
        #expect(result.peers.isEmpty)
        #expect(result.session == nil)
        #expect(result.refusal == .noSessionId)
    }
}

func adapterWiringEvent() -> IPCSessionEventIdentity {
    .init(
        name: .toolActivity, conversationId: "wire-main", turnId: nil, requestId: nil, toolId: nil,
        subagentId: nil, occurrenceId: UUIDv7.generate())
}
