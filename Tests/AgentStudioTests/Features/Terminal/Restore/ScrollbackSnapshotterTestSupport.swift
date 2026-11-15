import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

struct ScrollbackSnapshotterFixture {
    let clock = AgentStudioTestSupport.TestPushClock()
    let root: URL
    let store: ScrollbackStore
    let source: LocalFactSource<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact>
    let recorder: FactRecorder<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact>

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "scrollback-tick-\(UUIDv7.generate().uuidString)")
        let source = Self.makeSource()
        self.root = root
        store = ScrollbackStore(directoryURL: root)
        self.source = source
        recorder = try source.attach()
    }

    static func makeSource() -> LocalFactSource<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact> {
        LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .passFinished, .captureFinished, .retirementFinished, .quitFinished, .stopped: true
                    default: false
                    }
                }))
    }

    func nextPass(reason: ScrollbackPassReason) async throws -> ScrollbackSnapshotterScope {
        let scope = try await recorder.expectNextOperation(
            matching: { if case .pass = $0 { true } else { false } },
            opening: { $0 == .passStarted(reason) }, "scrollback \(reason) pass")
        try await recorder.expectNext(in: scope, .passStarted(reason))
        return scope
    }

    func nextCapture(_ binding: ScrollbackPaneBinding) async throws -> ScrollbackSnapshotterScope {
        let scope = try await recorder.expectNextOperation(
            matching: { if case .capture(let paneID, _) = $0 { paneID == binding.paneID } else { false } },
            opening: { $0 == .captureStarted(binding) }, "capture for the requested pane")
        try await recorder.expectNext(in: scope, .captureStarted(binding))
        return scope
    }

    func cleanup() async throws {
        var recordingError: (any Error)?
        do { try await recorder.finish() } catch { recordingError = error }
        try await withoutBlockingCooperativePool {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        if let recordingError { throw recordingError }
    }

    func finishPass(_ scope: ScrollbackSnapshotterScope, outcome: ScrollbackPassOutcome = .completed, count: Int)
        async throws
    {
        // Admissions may already be buffered while capture facts are consumed.
        // Drain typed facts through the closing fact rather than opening a
        // negative assertion after those admissions have happened.
        while true {
            let fact = try await recorder.expectNext(
                in: scope,
                where: {
                    switch $0 {
                    case .captureAdmitted, .captureJoined, .passFinished: true
                    default: false
                    }
                }, "capture admission, join, or pass completion")
            if case .passFinished(let actualOutcome, let actualCount) = fact {
                #expect(actualOutcome == outcome)
                #expect(actualCount == count)
                return
            }
        }
    }
}

actor ScrollbackCaptureFixtureBackend {
    private var bindings: [ScrollbackPaneBinding]
    private var inventory: ZmxSessionInventory
    private var results: [ZmxSessionID: ScrollbackCaptureResult]
    private let heldCaptures: [ZmxSessionID: HeldStep<ZmxSessionID>]
    private var callsBySession: [ZmxSessionID: Int] = [:]
    private var activeCount = 0
    private var maximumActiveCount = 0

    init(
        bindings: [ScrollbackPaneBinding], results: [ZmxSessionID: ScrollbackCaptureResult],
        inventory: ZmxSessionInventory? = nil,
        heldCaptures: [ZmxSessionID: HeldStep<ZmxSessionID>] = [:]
    ) {
        self.bindings = bindings
        self.results = results
        self.inventory =
            inventory
            ?? .complete(Dictionary(uniqueKeysWithValues: bindings.map { ($0.sessionID, .alive(wrapperPid: 1)) }))
        self.heldCaptures = heldCaptures
    }

    func discoverInventory() -> ZmxSessionInventory { inventory }
    func paneBindings() -> [ScrollbackPaneBinding] { bindings }
    func replaceResult(sessionID: ZmxSessionID, result: ScrollbackCaptureResult) { results[sessionID] = result }
    func addLiveBinding(_ binding: ScrollbackPaneBinding, result: ScrollbackCaptureResult) {
        bindings.append(binding)
        results[binding.sessionID] = result
        if case .complete(var entries) = inventory {
            entries[binding.sessionID] = .alive(wrapperPid: 1)
            inventory = .complete(entries)
        }
    }
    func callCount(for sessionID: ZmxSessionID) -> Int { callsBySession[sessionID, default: 0] }
    func peakConcurrency() -> Int { maximumActiveCount }
    func activeCaptureCount() -> Int { activeCount }

    func capture(_ sessionID: ZmxSessionID) async -> ScrollbackCaptureResult {
        callsBySession[sessionID, default: 0] += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        if let hold = heldCaptures[sessionID] {
            do { try await hold.arrive(sessionID) } catch { return .readFailed }
        }
        return results[sessionID] ?? .empty
    }
}
