import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer
@testable import AgentStudioSessions

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityMessageAgeTests {
    nonisolated static let activityAges: [Int?] = [nil, 0, 59]

    @Test(
        "stored message time survives publication and capture independently of fresh or missing activity",
        arguments: activityAges)
    func storedMessageOwnsItsAge(activityAge: Int?) async throws {
        let hasActivity = activityAge != nil
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Message clock")
            let paneId = PaneId(existingUUID: pane.id)
            let fixture = try await CompositionFactoryFixture.make(ownerId: paneId)
            do {
                try await writeMessage(fixture)
                await fixture.composition.presentationLane.publishPending()
                let readers = PaneContextUIReaders(
                    sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                    pane: { store.paneAtom.pane($0.uuid) })
                let reference = ContinuousClock.now
                let now = fixture.now.addingTimeInterval(125)
                if let activityAge {
                    atoms.paneActivityTime.apply([
                        .set(
                            pane.id,
                            .init(
                                orderingInstant: reference.advanced(by: .seconds(-activityAge)),
                                wallTime: now.addingTimeInterval(-Double(activityAge)), source: .terminal))
                    ])
                }
                let input = PaneManagementIdentityCapture.input(
                    context: .project(paneId: pane.id, store: store), store: store, readers: readers)
                #expect(input.agentLine?.updatedAt == fixture.now)
                #expect(input.activityTime?.wallTime == activityAge.map { now.addingTimeInterval(-Double($0)) })
                try await withMessageWatch(input, reference: reference, wallNow: now) { run in
                    try await run.facts.expectNext(in: 0, .published("2 min ago", hasActivity ? "Now" : "—"))
                    if activityAge == 59 {
                        try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(1))))
                        run.clock.advance(by: .seconds(1))
                        try await run.facts.expectNext(in: 0, .published("2 min ago", "1m"))
                        try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(55))))
                        run.clock.advance(by: .seconds(54))
                    } else {
                        try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(55))))
                        run.clock.advance(by: .seconds(55))
                    }
                    let chip = activityAge == 59 ? "1m" : (hasActivity ? "Now" : "—")
                    try await run.facts.expectNext(in: 0, .published("3 min ago", chip))
                    let nextSeconds = activityAge == 59 ? 61 : (hasActivity ? 60 : 115)
                    try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(nextSeconds))))
                    if !hasActivity {
                        run.clock.advance(to: run.start.advanced(by: .seconds(172_675)))
                        try await run.facts.expectNext(in: 0, .published("2 days ago", "—"))
                        try await run.facts.expectNext(in: 0, .sleep(run.start.advanced(by: .seconds(259_075))))
                    }
                    #expect(input.agentLine?.updatedAt == fixture.now)
                    #expect(store.paneAtom.pane(pane.id)?.title == "Message clock")
                }
                try await fixture.close()
            } catch {
                try? await fixture.close()
                throw error
            }
        }
    }

    private func writeMessage(_ fixture: CompositionFactoryFixture) async throws {
        let service = fixture.composition.paneContextService
        let writer = AgentMessageSender.pane(fixture.ownerId)
        let claim = await service.claimEpoch(
            .init(paneId: fixture.ownerId, writer: writer, stream: .line, claimId: UUIDv7.generate()))
        guard case .claimed(let epoch) = claim else {
            Issue.record("Message epoch refused: \(claim)")
            throw MessageWatchFailure()
        }
        try #require(
            await service.setLine(
                .init(
                    paneId: fixture.ownerId, writer: writer,
                    line: .init(summary: "A stored message", refs: []),
                    writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
    }
}

private struct MessageWatchFailure: Error {}

private enum MessageAgeFact: Equatable, Sendable {
    case published(String?, String)
    case sleep(TestPushClock.Instant)
    case finished
}

@MainActor
private final class MessageWatchRun {
    let facts: FactRecorder<Int, MessageAgeFact>
    let clock: TestPushClock
    let start: TestPushClock.Instant
    let task: Task<Void, Never>

    init(input: PaneManagementIdentityCapture.LineInput, reference: ContinuousClock.Instant, wallNow: Date) {
        let facts = FactRecorder<Int, MessageAgeFact>(
            vocabulary: .init(
                describeScope: { "message age \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .finished }))
        let clock = TestPushClock(pendingSleepFactSink: { fact in
            if case .registrationSettled(let deadline, _) = fact {
                facts.append(scope: 0, fact: .sleep(deadline))
            }
        })
        self.facts = facts
        self.clock = clock
        start = clock.now
        task = Task {
            await PaneManagementIdentityCapture.watch(
                input, clock: clock, referenceInstant: reference, wallNow: wallNow
            ) { presentation in
                let message = presentation.lines.compactMap { line -> RepoExplorerPaneContextLine? in
                    if case .agentLine(let value) = line { return value }
                    return nil
                }.first
                facts.append(scope: 0, fact: .published(message?.ageText, presentation.recencyText))
            }
            facts.append(scope: 0, fact: .finished)
            facts.receive(.ended)
        }
    }
}

@MainActor
private func withMessageWatch(
    _ input: PaneManagementIdentityCapture.LineInput, reference: ContinuousClock.Instant, wallNow: Date,
    body: (MessageWatchRun) async throws -> Void
) async throws {
    let run = MessageWatchRun(input: input, reference: reference, wallNow: wallNow)
    do {
        try await body(run)
        run.task.cancel()
        await run.task.value
        try await run.facts.expectNext(in: 0, .finished)
        #expect(run.clock.pendingSleepCount == 0)
        try await run.facts.finish()
    } catch {
        run.task.cancel()
        await run.task.value
        try? await run.facts.finish()
        throw error
    }
}
