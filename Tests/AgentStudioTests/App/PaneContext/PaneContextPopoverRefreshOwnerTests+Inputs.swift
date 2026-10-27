import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextPopoverRefreshOwnerTests {
    enum CanonicalChange: CaseIterable, Equatable, Sendable {
        case prompt, omittedPrompt, title, rawNote
    }

    @Test(
        "S3 canonical prompt, omitted-prompt, title and raw-note changes refresh only demanded inputs",
        arguments: CanonicalChange.allCases)
    func canonicalChangesRefreshOnlyAffectedConsumers(_ change: CanonicalChange) async throws {
        let pane = PaneId.generateUUIDv7()
        let other = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        let otherKey = PaneContextPopoverConsumerKey(hostId: UUIDv7.generate(), surface: .toolbar, paneId: other)
        let baseline = canonicalSource()
        let changed = canonicalSource(change)
        try #require(baseline != changed)
        #expect(baseline.display == changed.display)
        harness.capture.setSource(baseline, for: pane)
        do {
            let opened = try await harness.open(content: .toolbar)
            _ = try await harness.completed(opened.initialExecution)
            let unrelated = try await harness.open(otherKey, content: .toolbar)
            _ = try await harness.completed(unrelated.initialExecution, for: otherKey)
            let quiet = await harness.bridge.facts.mark(.init(channel: .lifetime(otherKey, unrelated.epoch)))
            harness.capture.setSource(changed, for: pane)
            await harness.owner.receive(harness.capture.snapshot(for: [pane]), for: harness.key, opening: opened.epoch)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await timer.task.value
            let execution = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(execution.id != opened.initialExecution.id)
            _ = try await harness.completed(execution)
            #expect(await harness.projections.requests.last?.capture.sources[pane] == changed)
            #expect(await harness.owner.latestExecution(for: otherKey)?.id == unrelated.initialExecution.id)
            #expect(await harness.ports.requests.isEmpty)
            await harness.owner.close(otherKey)
            try await harness.bridge.facts.expectNone(
                of: { fact in if case .owner(.admitted) = fact { true } else { false } },
                "work from another pane's canonical change", from: quiet, closedBy: { $0 == .owner(.retired) })
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 membership expansion recaptures new sources and detached sources no longer invalidate the consumer")
    func membershipJoinLeaveReconcilesSourceDemand() async throws {
        let pane = PaneId.generateUUIDv7()
        let child = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        harness.capture.setSource(structuralSource(pane, children: []), for: pane)
        do {
            let opened = try await harness.open(content: .toolbar)
            _ = try await harness.completed(opened.initialExecution)
            var prior = opened.initialExecution.id
            for children in [[child], []] {
                harness.capture.setSource(structuralSource(pane, children: children), for: pane)
                await harness.owner.receive(
                    harness.capture.snapshot(for: [pane, child]), for: harness.key, opening: opened.epoch)
                let timer = try await harness.timer()
                try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
                harness.clock.advance(by: .seconds(10))
                await timer.task.value
                let next = try #require(await harness.owner.latestExecution(for: harness.key))
                try #require(next.id != prior)
                _ = try await harness.completed(next)
                #expect(
                    Set(await harness.projections.requests.last?.capture.sources.keys.map { $0 } ?? [])
                        == Set([pane] + children))
                prior = next.id
            }
            let quiet = await harness.bridge.facts.mark(.init(channel: .lifetime(harness.key, opened.epoch)))
            let snapshot = try #require(await harness.projections.requests.last)
            await harness.owner.sourceInvalidated(
                .init(sourcePaneId: child, generation: 1), epoch: snapshot.identity.serviceEpoch)
            #expect(await harness.owner.scheduledWake() == nil)
            await harness.owner.close(harness.key)
            try await harness.bridge.facts.expectNone(
                of: { fact in if case .owner(.admitted) = fact { true } else { false } },
                "work from a detached source", from: quiet, closedBy: { $0 == .owner(.retired) })
            #expect(await harness.ports.requests.isEmpty)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 an exact focused ask outside the first page is read and supplemented")
    func exactFocusedAskBeyondFirstPageIsIncluded() async throws {
        let pane = PaneId.generateUUIDv7()
        let ask = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open),
            importance: .attention)
        let key = PaneContextMessageKey(paneId: pane, messageId: ask.id)
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        do {
            await harness.ports.configureExactReads([.found(ask)])
            let opened = try await harness.open(content: .messages(.message(key)))
            _ = try await harness.completed(opened.initialExecution)
            #expect(await harness.ports.exactRequests == [key])
            #expect(await harness.projections.shapes[harness.key]?.messages.messageRows.map(\.id) == [ask.id.uuid])
            #expect(await harness.projections.shapes[harness.key]?.messagesTarget == .message(key))
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    private func canonicalSource(_ change: CanonicalChange? = nil) -> PopoverSourceCapture.Source {
        .init(
            structuralFacts: nil, title: change == .title ? "Changed title" : "Owner",
            note: change == .rawNote ? "Raw note" : nil,
            session: .init(
                status: .needsYou(.approval),
                compactPrompt: .init(
                    reason: .approval, summary: change == .prompt ? "Changed prompt" : "Prompt",
                    observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    omittedOrFurtherCount: change == .omittedPrompt ? 2 : 0),
                promptListRevision: change == .prompt || change == .omittedPrompt ? 2 : 1),
            display: nil, activity: nil)
    }

    private func structuralSource(_ pane: PaneId, children: [PaneId]) -> PopoverSourceCapture.Source {
        let value = Pane(
            id: pane.uuid,
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/popover-membership"), title: "Owner"),
            kind: .layout(
                drawer: .init(drawerId: UUIDv7.generate(), parentPaneId: pane.uuid, paneIds: children.map(\.uuid))))
        return .init(
            structuralFacts: .init(state: .init(pane: value)), title: "Owner", note: nil, session: nil, display: nil,
            activity: nil)
    }
}
