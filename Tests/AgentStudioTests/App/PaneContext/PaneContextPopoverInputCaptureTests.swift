import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Demanded popover canonical observations", .serialized)
struct PaneContextPopoverInputCaptureTests {
    enum Change: CaseIterable, Sendable { case status, binding, title, note, activity, display, batch }

    @Test(
        "S4 keyed canonical observations copy the committed values after willSet and leave other consumers alone",
        arguments: Change.allCases)
    func canonicalChangesAreCapturedAfterAssignment(_ change: Change) async throws {
        let fixture = Fixture()
        let capture = fixture.makeCapture()
        let sink = Sink()
        capture.connect { key, opening, value in await sink.receive(key, opening: opening, value: value) }
        let key = fixture.key(fixture.pane)
        let other = fixture.key(.generateUUIDv7())
        do {
            _ = capture.capture(key, opening: 1, requestGeneration: 1, sources: [fixture.pane])
            _ = capture.capture(other, opening: 2, requestGeneration: 1, sources: [other.paneId])
            fixture.change(change)
            let producers = capture.forwardingTasks(for: key, opening: 1)
            try #require(!producers.isEmpty, "The canonical owner change did not announce a forwarding producer")
            #expect(capture.forwardingTasks(for: other, opening: 2).isEmpty)
            for task in producers { await task.value }
            let records = await sink.values
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.key == key)
            #expect(record.opening == 1)
            let source = try #require(record.value.sources[fixture.pane])
            switch change {
            case .status: #expect(source.session?.status == .needsYou(.approval))
            case .binding: #expect(source.session?.currentBindingId == fixture.nextBinding)
            case .title: #expect(source.title == "Changed title")
            case .note: #expect(source.note == "Changed note")
            case .activity: #expect(source.activity?.wallTime == fixture.now.addingTimeInterval(5))
            case .display: #expect(source.display?.own.kinds.needsYou == 3)
            case .batch:
                #expect(source.session?.status == .needsYou(.approval))
                #expect(source.display?.own.kinds.needsYou == 3)
            }
            await capture.stop()
        } catch {
            await capture.stop()
            throw error
        }
    }

    @Test("S4 close joins an in-flight forwarding producer and retires its observations")
    func closeJoinsForwardingAndStopsRearming() async throws {
        let fixture = Fixture()
        let capture = fixture.makeCapture()
        let held = HeldStep<PopoverSourceCapture>("canonical capture forwarded to its owner")
        let key = fixture.key(fixture.pane)
        capture.connect { _, _, value in try? await held.arrive(value) }
        var monitors: [Task<Void, Never>] = []
        do {
            _ = capture.capture(key, opening: 1, requestGeneration: 1, sources: [fixture.pane])
            fixture.change(.status)
            let producers = capture.forwardingTasks(for: key, opening: 1)
            try #require(!producers.isEmpty)
            let monitor = Task {
                for producer in producers { await producer.value }
                held.retire()
            }
            monitors.append(monitor)
            let forwarded = try await held.firstArrival()
            #expect(forwarded.sources[fixture.pane]?.session?.status == .needsYou(.approval))
            await capture.close(key, opening: 1)
            for producer in producers { #expect(producer.isCancelled) }
            #expect(capture.forwardingTasks(for: key, opening: 1).isEmpty)
            fixture.change(.title)
            #expect(capture.forwardingTasks(for: key, opening: 1).isEmpty)
            await capture.stop()
            for monitor in monitors { await monitor.value }
        } catch {
            held.retire()
            await capture.stop()
            for monitor in monitors { await monitor.value }
            throw error
        }
    }

    @Test("S4 a newly requested source is captured and observed before subsequent edits")
    func newSourceScopeInstallsItsObservation() async throws {
        let fixture = Fixture()
        let capture = fixture.makeCapture()
        let sink = Sink()
        capture.connect { key, opening, value in await sink.receive(key, opening: opening, value: value) }
        let key = fixture.key(fixture.pane)
        let child = PaneId.generateUUIDv7()
        do {
            _ = capture.capture(key, opening: 1, requestGeneration: 1, sources: [fixture.pane])
            fixture.status.apply([child: .set(.init(status: .idle(.ready)))])
            let joined = capture.capture(key, opening: 1, requestGeneration: 1, sources: [fixture.pane, child])
            #expect(joined.sources[child]?.session?.status == .idle(.ready))
            fixture.status.apply([child: .set(.init(status: .working(.active)))])
            let producers = capture.forwardingTasks(for: key, opening: 1)
            try #require(!producers.isEmpty)
            for producer in producers { await producer.value }
            #expect(await sink.values.last?.value.sources[child]?.session?.status == .working(.active))
            await capture.stop()
        } catch {
            await capture.stop()
            throw error
        }
    }

    enum StaleCapture: CaseIterable, Sendable { case request, opening }

    @Test("A late old capture cannot reinstall a removed source observation", arguments: StaleCapture.allCases)
    func staleCaptureCannotRestoreRemovedScope(_ stale: StaleCapture) async throws {
        let fixture = Fixture()
        let capture = fixture.makeCapture()
        let sink = Sink()
        let key = fixture.key(fixture.pane)
        let child = PaneId.generateUUIDv7()
        let currentOpening: UInt64 = stale == .opening ? 2 : 1
        capture.connect { key, opening, value in await sink.receive(key, opening: opening, value: value) }
        do {
            _ = capture.capture(key, opening: 1, requestGeneration: 1, sources: [fixture.pane, child])
            _ = capture.capture(key, opening: currentOpening, requestGeneration: 2, sources: [fixture.pane])
            let late = capture.capture(
                key, opening: 1, requestGeneration: stale == .opening ? 99 : 1,
                sources: [fixture.pane, child])
            #expect(Set(late.sources.keys) == [fixture.pane])
            fixture.status.apply([child: .set(.init(status: .working(.active)))])
            #expect(
                capture.forwardingTasks(for: key, opening: currentOpening).isEmpty,
                "The removed source must not synchronously announce another forwarding producer")
            fixture.change(.title)
            let producers = capture.forwardingTasks(for: key, opening: currentOpening)
            try #require(!producers.isEmpty, "The current owner observation must still be installed")
            for producer in producers { await producer.value }
            #expect(await sink.values.last?.opening == currentOpening)
            #expect(await sink.values.last?.value.sources[child] == nil)
            #expect(await sink.values.last?.value.sources[fixture.pane]?.title == "Changed title")
            await capture.stop()
        } catch {
            await capture.stop()
            throw error
        }
    }

    private actor Sink {
        struct Value: Sendable {
            let key: PaneContextPopoverConsumerKey
            let opening: UInt64
            let value: PopoverSourceCapture
        }
        private(set) var values: [Value] = []
        func receive(_ key: PaneContextPopoverConsumerKey, opening: UInt64, value: PopoverSourceCapture) {
            values.append(.init(key: key, opening: opening, value: value))
        }
    }

    @MainActor private final class Fixture {
        let pane = PaneId.generateUUIDv7()
        let epoch = UUIDv7.generate()
        let binding = UUIDv7.generate()
        let nextBinding = UUIDv7.generate()
        let status = SessionStatusAtom()
        let display = PaneContextPresentationAtom()
        let activity = PaneActivityTimeAtom()
        let graph = WorkspacePaneGraphAtom()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ordering = ContinuousClock().now

        init() {
            let value = Pane(
                id: pane.uuid,
                content: .terminal(
                    TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
                metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/popover-capture"), title: "Owner"),
                kind: .layout(drawer: .init(drawerId: UUIDv7.generate(), parentPaneId: pane.uuid)))
            #expect(graph.insertRestoredPane(value))
            status.apply([pane: .set(.init(status: .working(.active), currentBindingId: binding))])
        }
        func key(_ pane: PaneId) -> PaneContextPopoverConsumerKey {
            .init(hostId: UUIDv7.generate(), surface: .paneMessages, paneId: pane)
        }
        func makeCapture() -> PaneContextPopoverInputCapture {
            PaneContextPopoverInputCapture(
                serviceEpoch: { self.epoch },
                readSource: { pane in
                    .init(
                        structuralFacts: self.graph.paneStructuralFacts(pane.uuid),
                        title: self.graph.paneRawTitle(pane.uuid),
                        note: self.graph.paneRawNote(pane.uuid), session: self.status.value(for: pane),
                        display: self.display.value(for: pane), activity: self.activity.value(for: pane.uuid))
                })
        }
        func change(_ change: Change) {
            switch change {
            case .status: status.apply([pane: .set(.init(status: .needsYou(.approval), currentBindingId: binding))])
            case .binding: status.apply([pane: .set(.init(status: .working(.active), currentBindingId: nextBinding))])
            case .title: graph.updatePaneTitle(pane.uuid, title: "Changed title")
            case .note: graph.updatePaneNote(pane.uuid, note: "Changed note")
            case .activity:
                activity.apply([
                    .set(
                        pane.uuid,
                        .init(orderingInstant: ordering, wallTime: now.addingTimeInterval(5), source: .terminal))
                ])
            case .batch:
                self.change(.status)
                self.change(.display)
            case .display:
                let counts = PaneMessageCounts(
                    kinds: .init(failure: 0, needsYou: 3, done: 0, info: 0), newestOpenBlockingAskId: nil)
                display.apply([
                    pane: .set(
                        .init(
                            revision: .init(1), agentTitle: nil, agentLine: nil, own: counts, includingDrawers: counts,
                            pullRequests: .notApplicable))
                ])
            }
        }
    }
}
