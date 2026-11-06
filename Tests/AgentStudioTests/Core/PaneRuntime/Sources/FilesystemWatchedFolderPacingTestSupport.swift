import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

final class WatchedFolderScanSubmissionLog: @unchecked Sendable {
    struct Entry: Sendable {
        let request: WatchedFolderScanRequest
        let submittedAt: Duration
    }
    private let lock = NSLock()
    private var recorded: [Entry] = []
    var entries: [Entry] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded.removeAll() } }
    func record(_ request: WatchedFolderScanRequest, at now: Duration) {
        lock.withLock { recorded.append(.init(request: request, submittedAt: now)) }
    }
}

func makeWatchedFolderFixturePaths(count: Int) throws -> (root: URL, paths: [WatchedPath]) {
    precondition(count > 0)
    let root = FileManager.default.temporaryDirectory.appending(
        path: "filesystem-actor-watched-folder-\(UUIDv7.generate())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths: [WatchedPath]
    if count == 1 {
        paths = [WatchedPath(path: root)]
    } else {
        paths = try (0..<count).map { index in
            let path = root.appending(path: "root-\(index)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return WatchedPath(path: path)
        }
    }
    return (root, paths)
}

func triggerWatchedFolderChange(_ fixture: WatchedFolderActorFixture) async throws {
    let callbackID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
    await fixture.actor.handleWatchedFolderFSEvent(
        .init(
            worktreeId: callbackID, paths: [fixture.watchedFolder.appending(path: "candidate/.git/HEAD").path]))
}

func watchedFolderObservationIsAuthoritative(_ observation: WatchedFolderTopologyObservation) -> Bool {
    switch observation.coverage {
    case .authoritative: true
    case .additive: false
    }
}

func driveSustainedWatchedFolderBurst(
    _ fixture: WatchedFolderActorFixture, probe: WatchedFolderScanPacingProbe
) async throws -> [WatchedFolderScanSubmissionLog.Entry] {
    let origin = probe.clock.now
    var active: Task<Void, Never>?
    var nextDeadline: TestPushClock.Instant?
    var oldestUnserved = 0
    // This is the prescribed input trace, not a polling wait: each wake awaits its owner disposition.
    for second in 0..<60 {
        if second > 0 {
            probe.clock.advance(to: origin.advanced(by: .seconds(second)))
            if let deadline = nextDeadline, deadline <= probe.clock.now, let producer = active {
                if second - oldestUnserved == 10 {
                    try #require(await probe.nextDisposition(producedBy: producer) == .producerEnded)
                    await producer.value
                    active = nil
                    nextDeadline = nil
                } else {
                    let next = try await probe.nextSleep(producedBy: producer)
                    #expect(next == origin.advanced(by: .seconds(min(second + 1, oldestUnserved + 10))))
                    nextDeadline = next
                }
            }
        }
        try await triggerWatchedFolderChange(fixture)
        if active == nil {
            oldestUnserved = second
            let producer = try #require(await fixture.actor.watchedFolderScanState.pacingDeadlineTask)
            active = producer
            let deadline = try await probe.nextSleep(producedBy: producer)
            #expect(deadline == origin.advanced(by: .seconds(second + 2)))
            nextDeadline = deadline
        }
    }
    probe.clock.advance(to: origin.advanced(by: .seconds(60)))
    let producer = try #require(active)
    try #require(await probe.nextDisposition(producedBy: producer) == .producerEnded)
    await producer.value
    return fixture.submissionLog.entries
}
