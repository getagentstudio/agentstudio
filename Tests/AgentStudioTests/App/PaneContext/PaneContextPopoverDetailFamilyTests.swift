import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Popover eager-family prepared values", .serialized)
struct PaneContextPopoverDetailFamilyTests {
    @Test("S4 equal card paint retains the atom value and acknowledges the new useful deadline")
    func equalPaintAcknowledgesNewDeadline() async throws {
        let scenario = Scenario()
        let family = PaneContextPopoverDetailFamily()
        do {
            let atom = try #require(family.materialize(for: scenario.key))
            let port = try #require(family.projectionPort(for: scenario.key))
            let first = scenario.snapshot(generation: 1, activityOffset: 0)
            guard case .published(let initial) = await port.admit(first) else {
                Issue.record("The initial card value was not published")
                throw ProofFailure.missingPublication
            }
            #expect(initial.nextAgeBoundary == scenario.now.addingTimeInterval(60))
            let rendered = try #require(atom.value)
            #expect(rendered.card?.activityText == "Now")
            let second = scenario.snapshot(generation: 2, activityOffset: 5)
            guard case .equal(let receipt) = await port.admit(second) else {
                Issue.record("Equal rendered card paint was republished or lost its completion")
                throw ProofFailure.missingEqual
            }
            #expect(receipt.nextAgeBoundary == scenario.now.addingTimeInterval(65))
            #expect(atom.value === rendered)
            #expect(atom.latestAcceptedValue?.metadata.nextAgeBoundary == scenario.now.addingTimeInterval(65))
            #expect(atom.revision == 0)
            #expect(atom.isCurrent(second.identity))
            await family.stop()
        } catch {
            await family.stop()
            throw error
        }
    }

    @Test("S4 source revision metadata stays equal while changed message text publishes")
    func metadataEqualityDoesNotHideChangedText() async throws {
        let scenario = Scenario()
        let row = try PaneContextPopoverShapingTests.message(
            paneId: scenario.key.paneId, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        let family = PaneContextPopoverDetailFamily()
        do {
            let atom = try #require(family.materialize(for: scenario.key))
            let port = try #require(family.projectionPort(for: scenario.key))
            let first = scenario.snapshot(generation: 1, row: row)
            guard case .published = await port.admit(first) else { throw ProofFailure.missingPublication }
            let rendered = try #require(atom.value)
            let samePaint = scenario.snapshot(generation: 2, row: row)
            guard case .equal = await port.admit(samePaint) else {
                Issue.record("Unrendered detail revision forced a new value")
                throw ProofFailure.missingEqual
            }
            #expect(atom.value === rendered)
            #expect(atom.latestAcceptedValue?.shape?.revision == .init(2))
            let edited = AgentMessageDetail(
                id: row.id, sourcePaneId: row.sourcePaneId, sender: row.sender,
                sentAt: row.sentAt, sourceOccurredAt: row.sourceOccurredAt,
                importance: row.importance, body: "Changed visible body", why: row.why, actions: row.actions,
                shape: row.shape)
            guard case .published = await port.admit(scenario.snapshot(generation: 3, row: edited)) else {
                Issue.record("Changed body was suppressed as equal")
                throw ProofFailure.missingPublication
            }
            #expect(atom.value?.shape?.messages.messageRows.first?.body == "Changed visible body")
            #expect(atom.value !== rendered)
            #expect(atom.revision == 1)
            await family.stop()
        } catch {
            await family.stop()
            throw error
        }
    }

    @Test("S4 a retired port cannot recreate, revoke or remove a reopened slot")
    func retiredPortCannotAffectReopenedSlot() async throws {
        let scenario = Scenario()
        let family = PaneContextPopoverDetailFamily()
        do {
            let firstAtom = try #require(family.materialize(for: scenario.key))
            let oldPort = try #require(family.projectionPort(for: scenario.key))
            _ = await oldPort.admit(scenario.snapshot(generation: 1))
            await oldPort.retire()
            let nextAtom = try #require(family.materialize(for: scenario.key))
            #expect(firstAtom !== nextAtom)
            let nextPort = try #require(family.projectionPort(for: scenario.key))
            let current = scenario.snapshot(generation: 2, opening: 2)
            guard case .published = await nextPort.admit(current) else { throw ProofFailure.missingPublication }
            guard case .cancelled = await oldPort.admit(scenario.snapshot(generation: 3)) else {
                Issue.record("The old port admitted into the reopened key")
                throw ProofFailure.retiredPortAdmitted
            }
            oldPort.invalidate()
            await oldPort.retire()
            #expect(family.materialize(for: scenario.key) === nextAtom)
            #expect(nextAtom.isCurrent(current.identity))
            #expect(nextAtom.value?.card?.information.lines.first == .title("Owner"))
            await family.stop()
        } catch {
            await family.stop()
            throw error
        }
    }

    @Test("S4 the real family receives an owner age tick with no second storage read")
    func ownerAgeUsesRealFamily() async throws {
        let pane = PaneId.generateUUIDv7()
        let row = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [row]))
        let family = PaneContextPopoverDetailFamily()
        do {
            let atom = try #require(family.materialize(for: harness.key))
            let port = try #require(family.projectionPort(for: harness.key))
            let opening = try #require(
                await harness.owner.open(
                    harness.key,
                    demand: .init(
                        content: .messages(.top), location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
                    projection: port))
            #expect(try await harness.completed(opening.initialExecution) == .published)
            #expect(atom.value?.shape?.messages.messageRows.first?.age.text == "Now")
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(60)))
            harness.clock.advance(by: .seconds(60))
            await timer.task.value
            let tick = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(tick.id != opening.initialExecution.id)
            #expect(try await harness.completed(tick) == .published)
            #expect(atom.value?.shape?.messages.messageRows.first?.age.text == "1 min ago")
            #expect(await harness.ports.requests.count == 1)
            try await harness.finish()
            #expect(atom.freshness == .stopped)
            await family.stop()
        } catch {
            try? await harness.finish()
            await family.stop()
            throw error
        }
    }

    @Test("S4 a source invalidation across the MainActor handoff cannot be adopted as fresh")
    func revokedHandoffIsSuperseded() async throws {
        let scenario = Scenario()
        let family = PaneContextPopoverDetailFamily()
        do {
            let slot = try #require(family.materializedSlot(for: scenario.key))
            let port = try #require(family.projectionPort(for: scenario.key))
            // These are the real source and MainActor stages called by the projection port.
            let old = slot.prepare(scenario.snapshot(generation: 1))
            port.invalidate()
            guard case .superseded = await family.admit(old) else {
                Issue.record("The handoff adopted a source revision newer than its assembled snapshot")
                throw ProofFailure.retiredPortAdmitted
            }
            #expect(slot.atom.value == nil)
            let fresh = scenario.snapshot(generation: 2)
            guard case .published = await port.admit(fresh) else { throw ProofFailure.missingPublication }
            #expect(slot.atom.isCurrent(fresh.identity))
            #expect(slot.atom.value?.card?.information.lines.first == .title("Owner"))
            await family.stop()
        } catch {
            await family.stop()
            throw error
        }
    }

    @Test("S4 focused scroll tokens follow message content while feedback-only paint keeps its token")
    func focusedScrollTokenUsesPreparedContentEquality() async throws {
        let scenario = Scenario()
        let row = try PaneContextPopoverShapingTests.message(
            paneId: scenario.key.paneId, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        let family = PaneContextPopoverDetailFamily()
        do {
            let atom = try #require(family.materialize(for: scenario.key))
            let port = try #require(family.projectionPort(for: scenario.key))
            _ = await port.admit(scenario.snapshot(generation: 1, row: row))
            let first = try #require(atom.value)
            let token = try #require(first.messageScrollToken)
            _ = await port.admit(scenario.snapshot(generation: 2, row: row, feedback: "Dismissed"))
            let feedback = try #require(atom.value)
            #expect(feedback.publication.id != first.publication.id)
            #expect(feedback.messageScrollToken == token)
            _ = await port.admit(scenario.snapshot(generation: 3, activityOffset: 60, row: row))
            #expect(atom.value?.messageScrollToken != token)
            #expect(atom.value?.shape?.messages.messageRows.first?.age.text == "1 min ago")
            await family.stop()
        } catch {
            await family.stop()
            throw error
        }
    }

    enum CardPaintChange: Sendable, CaseIterable { case drawerStyle, sessionIdentity, sessionMetadata }

    @Test(
        "S4 card equality includes drawer style and SESSION identity but excludes non-rendered binding metadata",
        arguments: CardPaintChange.allCases)
    func cardEqualityTracksItsRenderedFields(_ change: CardPaintChange) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Same owner")
            let parent = store.createPane(title: "Parent")
            defer {
                store.removePane(pane.id)
                store.removePane(parent.id)
            }
            let key = PaneContextPopoverConsumerKey(
                hostId: UUIDv7.generate(), surface: .managementCard,
                paneId: .init(existingUUID: pane.id))
            let epoch = UUIDv7.generate()
            let firstSession = try Self.makeSessionSummary("A")
            let secondSession = try Self.makeSessionSummary(change == .sessionIdentity ? "B" : "A")
            let layout = PaneStructuralFacts(state: PaneGraphState(pane: pane))
            var moved = pane
            moved.kind = .drawerChild(parentPaneId: parent.id)
            let drawer = PaneStructuralFacts(state: PaneGraphState(pane: moved))
            func snapshot(_ generation: UInt64, facts: PaneStructuralFacts, session: SessionSummary)
                -> PaneContextPopoverSnapshot
            {
                .init(
                    identity: .init(
                        key: key, openingEpoch: 1, serviceEpoch: epoch, requestGeneration: generation,
                        inputGeneration: generation, ageGeneration: 0, pageGeneration: 0,
                        producer: .execution(UUIDv7.generate())),
                    demand: .init(content: .card, location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
                    capture: .init(
                        observationGeneration: generation, serviceEpoch: epoch,
                        sources: [
                            key.paneId: .init(
                                structuralFacts: facts, title: "Same owner", note: nil,
                                session: nil, display: nil, activity: nil)
                        ]),
                    state: .ready(.compact), wallNow: .distantPast, frozenWidth: 480, liveSession: session)
            }
            let family = PaneContextPopoverDetailFamily()
            do {
                let atom = try #require(family.materialize(for: key))
                let port = try #require(family.projectionPort(for: key))
                guard case .published = await port.admit(snapshot(1, facts: layout, session: firstSession)) else {
                    throw ProofFailure.missingPublication
                }
                let initial = try #require(atom.value)
                let next = snapshot(2, facts: change == .drawerStyle ? drawer : layout, session: secondSession)
                let outcome = await port.admit(next)
                switch change {
                case .drawerStyle:
                    guard case .published = outcome else {
                        Issue.record("A visible drawer-title style change was suppressed as equal")
                        throw ProofFailure.missingPublication
                    }
                    #expect(atom.value?.isDrawer == true)
                case .sessionIdentity:
                    guard case .published = outcome else {
                        Issue.record("A visible SESSION identity change was suppressed as equal")
                        throw ProofFailure.missingPublication
                    }
                    #expect(atom.value?.liveSession?.sessionRef.value == "B")
                case .sessionMetadata:
                    guard case .equal = outcome else {
                        Issue.record("Non-rendered binding metadata forced a new card value")
                        throw ProofFailure.missingEqual
                    }
                    #expect(atom.value === initial)
                    #expect(atom.latestAcceptedValue?.liveSession?.bindingGeneration == secondSession.bindingGeneration)
                }
                await family.stop()
            } catch {
                await family.stop()
                throw error
            }
        }
    }

    private static func makeSessionSummary(_ reference: String) throws -> SessionSummary {
        .init(
            id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init(reference),
            bindingGeneration: UUIDv7.generate(), status: .working(.active), providerPrompts: [])
    }

    @Test("A cancelled older admission cannot revoke the newer prepared value on the same slot")
    func oldCancellationCannotRevokeNewerAdmission() async throws {
        let scenario = Scenario()
        let family = PaneContextPopoverDetailFamily()
        do {
            let slot = try #require(family.materializedSlot(for: scenario.key))
            let port = try #require(family.projectionPort(for: scenario.key))
            let old = slot.prepare(scenario.snapshot(generation: 1))
            slot.invalidate()
            let current = scenario.snapshot(generation: 2)
            guard case .published = await port.admit(current) else { throw ProofFailure.missingPublication }
            try #require(slot.atom.isCurrent(current.identity))
            let currentRevision = slot.sourceRevision.current
            old.cancel()
            #expect(
                slot.sourceRevision.current == currentRevision,
                "Cancellation may only revoke the source revision captured by its own admission")
            #expect(slot.atom.isCurrent(current.identity), "The newer input/reader frame must remain current")
            await family.stop()
        } catch {
            await family.stop()
            throw error
        }
    }

    private struct Scenario {
        let key = PaneContextPopoverConsumerKey(
            hostId: UUIDv7.generate(), surface: .managementCard, paneId: .generateUUIDv7())
        let epoch = UUIDv7.generate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let orderingInstant = ContinuousClock().now

        func snapshot(
            generation: UInt64, opening: UInt64 = 1, activityOffset: TimeInterval = 0, row: AgentMessageDetail? = nil,
            feedback: String? = nil
        ) -> PaneContextPopoverSnapshot {
            let state: PaneContextPopoverSnapshot.State
            let content: PaneContextPopoverDemand.Content
            if let row {
                let detail = PaneContextDetail(
                    paneId: key.paneId, revision: .init(generation), agentTitle: nil, agentLine: nil,
                    scopedSessions: [.init(sourcePaneId: key.paneId, session: nil)], hasDismissibleNotices: true,
                    messages: [row], drawerMessages: [], links: .unknown, pullRequests: .notApplicable, truncation: nil)
                state = .ready(.detail(detail))
                content = .messages(.top)
            } else {
                state = .ready(.compact)
                content = .card
            }
            return .init(
                identity: .init(
                    key: key, openingEpoch: opening, serviceEpoch: epoch, requestGeneration: generation,
                    inputGeneration: generation, ageGeneration: 0, pageGeneration: 0,
                    producer: .execution(UUIDv7.generate())),
                demand: .init(content: content, location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
                capture: .init(
                    observationGeneration: generation, serviceEpoch: epoch,
                    sources: [
                        key.paneId: .init(
                            structuralFacts: nil, title: "Owner", note: nil, session: nil, display: nil,
                            activity: .init(
                                orderingInstant: orderingInstant, wallTime: now.addingTimeInterval(activityOffset),
                                source: .terminal))
                    ]),
                state: state, wallNow: now.addingTimeInterval(activityOffset), frozenWidth: 480,
                actionFeedback: feedback)
        }
    }
    private enum ProofFailure: Error { case missingPublication, missingEqual, retiredPortAdmitted }
}
