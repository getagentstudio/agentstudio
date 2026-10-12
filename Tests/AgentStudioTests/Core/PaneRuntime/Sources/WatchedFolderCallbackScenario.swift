import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

enum WatchedFolderCallbackStimulus {
    case path(String)
    case overflow(paths: Set<String>?, requiresScan: Bool, trigger: String)
}

struct WatchedFolderCallbackScenario {
    let fixture: WatchedFolderActorFixture
    private let client: ControllableFSEventStreamClient
    private let window: FilesystemCallbackWindow
    private let facts: FactRecorder<UInt64, FilesystemCallbackFact>

    init() async throws {
        let window = FilesystemCallbackWindow()
        let source = LocalFactSource(
            vocabulary: FactVocabulary<UInt64, FilesystemCallbackFact>(
                describeScope: { "watched callback window \($0)" },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .acknowledged = fact { return true }
                    return false
                }))
        facts = try source.attach()
        let client = ControllableFSEventStreamClient()
        let observedClient = FilesystemFencedStreamClient(
            base: client, onAcknowledgement: { source.sink($0.rawValue, .acknowledged($0)) })
        fixture = try await WatchedFolderActorFixture(
            fseventClient: client, onCallbackSubmission: { source.sink(window.identifier, .submitted($0)) },
            observedStreamClient: observedClient)
        self.window = window
        self.client = client
    }

    func rejectScan(_ stimulus: WatchedFolderCallbackStimulus, closingID: UInt64, baselineCount: Int) async throws {
        window.select(closingID)
        let opening = await facts.mark(closingID)
        try send(stimulus)
        let close = FSEventActivityProcessingFenceID(rawValue: closingID)
        client.sendActivityProcessingFence(close)
        try await facts.expectNone(
            of: {
                if case .submitted = $0 { return true }
                return false
            },
            "ordinary callback scan",
            from: opening,
            closedBy: {
                if case .acknowledged(let fence) = $0 { return fence == close }
                return false
            })
        #expect(await fixture.scanner.startedQuantumCount() == baselineCount)
    }

    func requireScan(_ stimulus: WatchedFolderCallbackStimulus, closingID: UInt64, expectedCount: Int) async throws
        -> ControlledActorWatchedFolderScanner.Start
    {
        window.select(closingID)
        try send(stimulus)
        let close = FSEventActivityProcessingFenceID(rawValue: closingID)
        client.sendActivityProcessingFence(close)
        let admitted = try await facts.expectNext(
            in: closingID,
            where: {
                if case .submitted = $0 { return true }
                return false
            }, "Git callback submission")
        let start = await fixture.scanner.nextStart()
        if case .submitted(let request) = admitted {
            #expect(start.request == request)
            #expect(request.sourceID.rootID == fixture.watchedPath.id)
            #expect(request.cause == .callback)
        }
        _ = try await facts.expectNext(
            in: closingID,
            where: {
                if case .acknowledged(let fence) = $0 { return fence == close }
                return false
            }, "Git callback ingress acknowledged")
        await fixture.scanner.finish(start, with: completeResult(entries: []))
        #expect(await fixture.scanner.startedQuantumCount() == expectedCount)
        return start
    }

    func shutdown() async throws {
        await fixture.shutdown()
        try await facts.finish()
    }

    private func send(_ stimulus: WatchedFolderCallbackStimulus) throws {
        let routingID = try #require(client.registeredWorktreeIds.first)
        let relativePath: String
        switch stimulus {
        case .path(let path):
            relativePath = path
        case .overflow(let paths, let requiresScan, let trigger):
            client.sendOverflowRecovery(
                worktreeId: routingID,
                paths: paths.map { Set($0.map { fixture.watchedFolder.appending(path: $0).path }) },
                requiresWatchedFolderScan: requiresScan)
            relativePath = trigger
        }
        client.send(
            FSEventBatch(
                worktreeId: routingID, paths: [fixture.watchedFolder.appending(path: relativePath).path]))
    }
}
