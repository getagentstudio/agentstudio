import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Native Agent Line contents", .serialized)
struct PaneContextAgentLinePopoverNativeTests {
    @Test("O50 full line, bracketed age, writer and references render without the loaded E7 prompts")
    func fullLineReferencesAndAttributionExcludeProviderPrompts() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let signal = SessionProviderSignal.elicitation(id: "prompt", summary: "A provider-only prompt")
            let result = try await fixture.composition.ingestion.submitHook(
                .init(
                    paneId: fixture.ownerId.uuid,
                    providerIdentifier: "codex", providerVersion: "9.9.9", sessionId: "agent-line-provider",
                    eventName: signal.name, turnId: nil, signal: signal, recordId: UUIDv7.generate(),
                    admittedAt: fixture.now, chain: TestMainAgentChain.observation))
            guard case .committed = result else { throw AgentLineNativeProofFailure.missingDetail }
            let binding = try #require(
                try await fixture.composition.ingestion.repository.statusContext(paneId: fixture.ownerId.uuid)
                    .currentBinding)
            let writer = try fixture.sender(binding)
            guard
                case .claimed(let epoch) = await service.claimEpoch(
                    .init(
                        paneId: fixture.ownerId,
                        writer: writer, stream: .line, claimId: UUIDv7.generate()))
            else { throw AgentLineNativeProofFailure.missingDetail }
            let summary =
                "Applying migration 3 of 7 to the sessions table and rebuilding indexes while preserving every diagnostic and reference."
            let path = "Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion.swift"
            let identity = try ForgePullRequestIdentity(
                host: "github.com", owner: "reference-owner", repository: "reference-repo", number: 7)
            try #require(
                await service.setLine(
                    .init(
                        paneId: fixture.ownerId, writer: writer,
                        line: .init(
                            summary: summary, refs: [.openFile(path: path, line: 142), .openPullRequest(identity)]),
                        writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
            guard case .detail(let detail) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first)),
                let line = detail.agentLine
            else { throw AgentLineNativeProofFailure.missingDetail }
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let sourceOwners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let now = fixture.now.addingTimeInterval(120)
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let mounted = PaneContextPreparedNativeHost(
                paneId: fixture.ownerId, sourceOwners: sourceOwners,
                entry: .agentLine(.agent(line, now: now)), clock: clock, wallNow: { now }, bridge: bridge,
                location: .sidebar)
            window = mounted
            try await mounted.open()
            try mounted.appliedAgentLine(summary: summary, age: "2 min ago")
            #expect(mounted.value?.shape.map(PaneContextPopoverShapingTests.prompts)?.count == 1)
            #expect(mounted.native.labels().contains(summary + " [2 min ago]"))
            #expect(mounted.native.labels().contains("codex · agent-line-provider"))
            #expect(mounted.native.labels().contains(path))
            #expect(mounted.native.labels().contains("Line 142"))
            #expect(mounted.native.labels().contains("reference-owner/reference-repo #7"))
            #expect(!mounted.native.labels().contains { $0.contains("A provider-only prompt") })
            #expect(mounted.native.find("pane-context.group.needsYou") == nil)
            #expect(mounted.native.find("pane-context.go-to-pane") != nil)
            #expect((mounted.native.find("pane-context.popover-panel") as? NSView)?.bounds.width == 380)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }
}

private enum AgentLineNativeProofFailure: Error { case missingDetail }
