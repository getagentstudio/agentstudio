import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Arrangements demanded session", .serialized)
struct ArrangementPanelSessionTests {
    @Test("Agent Line age refreshes at its boundary and close joins the deadline")
    func agentLineAgeDeadline() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = ArrangementSessionFixture(atoms: atoms)
            let facts = arrangementSessionFacts()
            let clock = TestPushClock(pendingSleepFactSink: { fact in
                if case .registrationSettled = fact { facts.append(scope: 0, fact: .ageDeadline) }
            })
            let origin = clock.now
            let pane = PaneId(existingUUID: fixture.paneId)
            atoms.paneContextPresentation.apply([
                pane: .set(
                    .init(
                        revision: .init(1), agentTitle: nil,
                        agentLine: .init(
                            summary: "Reviewing changes", refs: [], writer: .pane(pane),
                            updatedAt: Date(timeIntervalSince1970: 875)),
                        own: .zero, includingDrawers: .zero, pullRequests: .notApplicable))
            ])
            let session = ArrangementPanelSession(
                sources: fixture.sources, project: { try await ArrangementTableProjector.project($0) },
                onCompletion: { facts.append(scope: 0, fact: .completed($0)) }, delay: .clock(clock),
                wallNow: {
                    Date(timeIntervalSince1970: 1000 + Double(origin.duration(to: clock.now).components.seconds))
                })
            let producer = session.beginArrangementProjection(tabId: fixture.tabId)
            let ended = Task {
                await producer.value
                facts.append(scope: 0, fact: .finished)
                facts.receive(.ended)
            }
            do {
                try await facts.expectNext(in: 0, .completed(true))
                #expect(session.presentation?.panes.first?.agentLine == "Reviewing changes [2 min ago]")
                try await facts.expectNext(in: 0, .ageDeadline)
                #expect(clock.pendingSleepDeadlines == [origin.advanced(by: .seconds(55))])
                clock.advance(by: .seconds(55))
                try await facts.expectNext(in: 0, .completed(true))
                #expect(session.presentation?.panes.first?.agentLine == "Reviewing changes [3 min ago]")
                try await facts.expectNext(in: 0, .ageDeadline)
                await session.retireArrangementProjection()?.value
                await ended.value
                try await facts.expectNext(in: 0, .finished)
                #expect(clock.pendingSleepCount == 0)
                #expect(session.presentation == nil)
                try await facts.finish()
            } catch {
                await session.retireArrangementProjection()?.value
                await ended.value
                try? await facts.finish()
                throw error
            }
        }
    }

    @Test("an invalidated held generation cannot bind before its current successor")
    func rejectsMixedGeneration() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = ArrangementSessionFixture(atoms: atoms)
            let paneId = fixture.paneId
            let facts = arrangementSessionFacts()
            let workerContext = ExecutionContextRecorder()
            let held = HeldStep<String>("first Arrangements row projection")
            let currentHeld = HeldStep<String>("current Arrangements row projection")
            let first = Mutex(true)
            let session = ArrangementPanelSession(
                sources: fixture.sources,
                project: { input in
                    workerContext.record()
                    let mustHold = first.withLock { value in
                        let prior = value
                        value = false
                        return prior
                    }
                    if mustHold {
                        let title = input.sources[paneId]?.state.title ?? "missing"
                        try await held.arrive(
                            title,
                            onArrivalPublished: {
                                facts.append(scope: 0, fact: .held(title))
                            })
                    } else {
                        let title = input.sources[paneId]?.state.title ?? "missing"
                        try await currentHeld.arrive(
                            title,
                            onArrivalPublished: { facts.append(scope: 0, fact: .held(title)) })
                    }
                    return try await ArrangementTableProjector.project(input)
                },
                onCompletion: { facts.append(scope: 0, fact: .completed($0)) },
                wallNow: { Date(timeIntervalSince1970: 1000) })
            let producer = session.beginArrangementProjection(tabId: fixture.tabId)
            let ended = Task {
                await producer.value
                facts.append(scope: 0, fact: .finished)
                facts.receive(.ended)
            }
            do {
                try await facts.expectNext(in: 0, .held("Original"))
                #expect(workerContext.wasOnMainThread == false)
                fixture.store.paneAtom.updatePaneTitle(fixture.paneId, title: "Current")
                #expect(session.presentation == nil)
                held.release()
                try await facts.expectNext(in: 0, .completed(false))
                try await facts.expectNext(in: 0, .held("Current"))
                #expect(session.presentation == nil)
                currentHeld.release()
                try await facts.expectNext(in: 0, .completed(true))
                #expect(session.presentation?.panes.first?.title == "Current")
                await session.retireArrangementProjection()?.value
                await ended.value
                try await facts.expectNext(in: 0, .finished)
                try await facts.finish()
            } catch {
                held.retire()
                currentHeld.retire()
                await session.retireArrangementProjection()?.value
                await ended.value
                try? await facts.finish()
                throw error
            }
        }
    }

    @Test("close revokes held work, reopen joins it, and closed sources perform no captures")
    func closeReopenRetiresPriorOpening() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = ArrangementSessionFixture(atoms: atoms)
            let facts = arrangementSessionFacts()
            let held = HeldStep<Void>("retired Arrangements opening", cancellation: .holdThroughCancellation)
            let first = Mutex(true)
            let session = ArrangementPanelSession(
                sources: fixture.sources,
                project: { input in
                    let mustHold = first.withLock { value in
                        let prior = value
                        value = false
                        return prior
                    }
                    if mustHold {
                        try await held.arrive(
                            (), onArrivalPublished: { facts.append(scope: 1, fact: .held("Original")) })
                    }
                    return try await ArrangementTableProjector.project(input)
                },
                onCompletion: { facts.append(scope: 2, fact: .completed($0)) })
            let firstProducer = session.beginArrangementProjection(tabId: fixture.tabId)
            let firstEnded = Task {
                await firstProducer.value
                facts.append(scope: 1, fact: .finished)
            }
            var secondEnded: Task<Void, Never>?
            do {
                try await facts.expectNext(in: 1, .held("Original"))
                let retirement = session.retireArrangementProjection()
                #expect(session.presentation == nil)
                fixture.store.paneAtom.updatePaneTitle(fixture.paneId, title: "Reopened")
                #expect(fixture.captures.value == 1)
                let secondProducer = session.beginArrangementProjection(tabId: fixture.tabId)
                secondEnded = Task {
                    await secondProducer.value
                    facts.append(scope: 2, fact: .finished)
                }
                held.release()
                await retirement?.value
                try await facts.expectNext(in: 1, .finished)
                try await facts.expectNext(in: 2, .completed(true))
                #expect(session.presentation?.panes.first?.title == "Reopened")
                #expect(fixture.captures.value == 2)
                await session.retireArrangementProjection()?.value
                await secondEnded?.value
                await firstEnded.value
                try await facts.expectNext(in: 2, .finished)
                fixture.store.paneAtom.updatePaneTitle(fixture.paneId, title: "Closed")
                #expect(fixture.captures.value == 2)
                facts.receive(.ended)
                try await facts.finish()
            } catch {
                held.retire()
                await session.retireArrangementProjection()?.value
                await firstEnded.value
                await secondEnded?.value
                facts.receive(.ended)
                try? await facts.finish()
                throw error
            }
        }
    }

    @Test("equal semantic rows do not republish and a previously absent display becomes visible")
    func equalRowsAndAbsentKey() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = ArrangementSessionFixture(atoms: atoms)
            let facts = arrangementSessionFacts()
            let session = ArrangementPanelSession(
                sources: fixture.sources, project: { try await ArrangementTableProjector.project($0) },
                onCompletion: { facts.append(scope: 0, fact: .completed($0)) },
                wallNow: { Date(timeIntervalSince1970: 1000) })
            let producer = session.beginArrangementProjection(tabId: fixture.tabId)
            let ended = Task {
                await producer.value
                facts.append(scope: 0, fact: .finished)
                facts.receive(.ended)
            }
            do {
                try await facts.expectNext(in: 0, .completed(true))
                let pane = PaneId(existingUUID: fixture.paneId)
                atoms.paneContextPresentation.apply([
                    pane: .set(
                        .init(
                            revision: .init(1), agentTitle: nil, agentLine: nil,
                            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable))
                ])
                try await facts.expectNext(in: 0, .completed(false))
                let line = AgentLineDetail(
                    summary: "Summary only", refs: [], writer: .pane(pane), updatedAt: Date(timeIntervalSince1970: 1000)
                )
                atoms.paneContextPresentation.apply([
                    pane: .set(
                        .init(
                            revision: .init(2), agentTitle: nil, agentLine: line,
                            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable))
                ])
                try await facts.expectNext(in: 0, .completed(true))
                #expect(session.presentation?.panes.first?.agentLine == "Summary only [Now]")
                await session.retireArrangementProjection()?.value
                await ended.value
                try await facts.expectNext(in: 0, .finished)
                try await facts.finish()
            } catch {
                await session.retireArrangementProjection()?.value
                await ended.value
                try? await facts.finish()
                throw error
            }
        }
    }

    @Test("a last-row Line change notifies presentation readers while equal rows do not publish")
    func lastRowChangePublishesObservedPresentation() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = ArrangementSessionFixture(atoms: atoms, paneCount: 3)
            let lastPane = PaneId(existingUUID: try #require(fixture.paneIds.last))
            let facts = arrangementSessionFacts()
            let observations = Mutex(0)
            let session = ArrangementPanelSession(
                sources: fixture.sources, project: { try await ArrangementTableProjector.project($0) },
                onCompletion: { facts.append(scope: 0, fact: .completed($0)) },
                wallNow: { Date(timeIntervalSince1970: 1000) })
            let producer = session.beginArrangementProjection(tabId: fixture.tabId)
            let ended = Task {
                await producer.value
                facts.append(scope: 0, fact: .finished)
                facts.receive(.ended)
            }
            @MainActor func publishLine(_ summary: String, revision: PaneContextRevision) {
                atoms.paneContextPresentation.apply([
                    lastPane: .set(
                        .init(
                            revision: revision, agentTitle: nil,
                            agentLine: .init(
                                summary: summary, refs: [], writer: .pane(lastPane),
                                updatedAt: Date(timeIntervalSince1970: 1000)),
                            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable))
                ])
            }
            @MainActor func observePresentation() {
                withObservationTracking {
                    _ = session.presentation
                } onChange: {
                    observations.withLock { $0 += 1 }
                }
            }
            do {
                try await facts.expectNext(in: 0, .completed(true))
                let initialRows = try #require(session.presentation?.panes)
                #expect(initialRows.map(\.id) == fixture.paneIds)
                observePresentation()

                publishLine("Last row only", revision: .init(1))
                try await facts.expectNext(in: 0, .completed(true))
                #expect(observations.withLock { $0 } == 1)
                #expect(session.presentation?.panes.last?.agentLine == "Last row only [Now]")
                #expect(session.presentation?.panes.dropLast() == initialRows.dropLast())
                observePresentation()

                publishLine("Last row only", revision: .init(2))
                try await facts.expectNext(in: 0, .completed(false))
                #expect(observations.withLock { $0 } == 1)

                publishLine("Last row updated", revision: .init(3))
                try await facts.expectNext(in: 0, .completed(true))
                #expect(observations.withLock { $0 } == 2)
                #expect(session.presentation?.panes.last?.agentLine == "Last row updated [Now]")
                #expect(session.presentation?.panes.dropLast() == initialRows.dropLast())
                await session.retireArrangementProjection()?.value
                await ended.value
                try await facts.expectNext(in: 0, .finished)
                try await facts.finish()
            } catch {
                await session.retireArrangementProjection()?.value
                await ended.value
                try? await facts.finish()
                throw error
            }
        }
    }
}

private enum ArrangementSessionFact: Equatable, Sendable {
    case held(String)
    case completed(Bool)
    case finished
    case ageDeadline
}

private func arrangementSessionFacts() -> FactRecorder<Int, ArrangementSessionFact> {
    .init(
        vocabulary: .init(
            describeScope: { "Arrangements opening \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .finished }))
}

@MainActor
private final class ArrangementCaptureCount { var value = 0 }

@MainActor
private struct ArrangementSessionFixture {
    let store: WorkspaceStore
    let paneId: UUID
    let paneIds: [UUID]
    let tabId: UUID
    let sources: ArrangementPanelSources
    let captures = ArrangementCaptureCount()

    init(atoms: CoreAtoms, paneCount: Int = 1) {
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        self.store = store
        paneIds = (0..<paneCount).map { store.createPane(title: $0 == 0 ? "Original" : "Pane \($0)").id }
        paneId = paneIds[0]
        let arrangement = PaneArrangement(name: "Default", isDefault: true, layout: .autoTiled(paneIds))
        let tab = Tab(allPaneIds: paneIds, arrangements: [arrangement], activeArrangementId: arrangement.id)
        tabId = tab.id
        store.appendTab(tab)
        let counter = captures
        sources = .init(
            store: store, repoCache: atoms.repoCache,
            contextDisplay: { pane in
                counter.value += 1
                return atoms.paneContextPresentation.value(for: pane)
            },
            shellExecutablePath: "/bin/zsh")
    }
}
