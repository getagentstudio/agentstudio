import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

private struct DescriptorLifetimeFixture: Sendable {
    let testQueue: DispatchQueue
    let openRecorder: FactRecorder<String, Int32>
    let closeRecorder: FactRecorder<String, Int32>
    let cancellationRequestedRecorder: FactRecorder<String, Void>
    let openSink: @Sendable (String, Int32) -> Void
    let closeSink: @Sendable (String, Int32) -> Void
    let cancellationRequestedSink: @Sendable (String, Void) -> Void
}

/// N1 (advisor review round 2, Lead 2026-10-02): proves
/// `awaitSessionIdentityOnRealEvent`'s own watched directory descriptor
/// (`ZmxE2ETests+RealEventWaits.swift`) stays open until its dispatch
/// source's cancellation has actually completed -- the same A4-shaped
/// lifetime defect `ColdStartObserverWatchSourceOwnershipTests
/// .directoryDescriptorStaysOpenUntilCancellationCompletes` already proves
/// fixed for the production observer's own directory watch, repeated here
/// in this file's separately-added real-event helper. Before this fix, a
/// bare `defer { close(directoryFileDescriptor) }` ran the instant this
/// function unwound -- immediately after requesting cancellation, not once
/// cancellation had actually completed (`dispatch_source_cancel` is
/// asynchronous, SDK source.h:512).
///
/// Same `testQueue.suspend()` technique as that production test: the
/// underlying `source.resume()` still proceeds regardless of the target
/// queue's suspend state (SDK source.h:745's own registration contract),
/// but the *handler block* -- including the cancel handler that now owns
/// the real close -- cannot run on a suspended queue. That is what lets
/// this test observe "requested, not yet completed" as a real, held-open
/// window instead of racing real kqueue/libdispatch timing.
///
/// `AlwaysAbsentSessionRestoreProbe` always reports the session's socket as
/// absent, so the function under test never resolves an identity on its
/// own and never leaves its directory-event retry loop -- the only
/// suspension it ever reaches is this test's own cancellation.
extension E2ESerializedTests.ZmxE2ETests {
    @Test(
        "awaitSessionIdentityOnRealEvent keeps its watched directory descriptor open until cancellation actually completes"
    )
    func sessionIdentityWaitDescriptorStaysOpenUntilCancellationCompletes() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "zmx-e2e-n1-fd-lifetime-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixture = try makeDescriptorLifetimeFixture()
        let harness = await ZmxTestHarness()
        let scenarioResult = await driveDescriptorLifetimeScenario(
            fixture: fixture, harness: harness, zmxDirectoryPath: temporaryDirectory.path)
        let cleanupOutcome = await harness.cleanup()
        #expect(cleanupOutcome.succeeded, "harness cleanup failed: \(cleanupOutcome.diagnostics)")
        try scenarioResult.get()
    }

    private func makeDescriptorLifetimeFixture() throws -> DescriptorLifetimeFixture {
        let testQueue = DispatchQueue(label: "zmx-e2e-n1-test-queue", qos: .userInitiated)
        testQueue.suspend()
        let openSource = LocalFactSource(vocabulary: Self.fileDescriptorFactVocabulary())
        let closeSource = LocalFactSource(vocabulary: Self.fileDescriptorFactVocabulary())
        let cancellationRequestedSource = LocalFactSource(
            vocabulary: FactVocabulary<String, Void>(
                describeScope: { $0 },
                describeFact: { _ in "cancellation requested" },
                isClosing: { _, _ in true }
            ))
        return DescriptorLifetimeFixture(
            testQueue: testQueue,
            openRecorder: try openSource.attach(),
            closeRecorder: try closeSource.attach(),
            cancellationRequestedRecorder: try cancellationRequestedSource.attach(),
            openSink: openSource.sink,
            closeSink: closeSource.sink,
            cancellationRequestedSink: cancellationRequestedSource.sink
        )
    }

    private func driveDescriptorLifetimeScenario(
        fixture: DescriptorLifetimeFixture,
        harness: ZmxTestHarness,
        zmxDirectoryPath: String
    ) async -> Result<Void, any Error> {
        var eventQueueIsSuspended = true
        var cancelledWaitTask: Task<Data, any Error>?
        var cancelledWaitJoinStep: HeldStep<Bool>?
        var cancelledWaitJoinTask: Task<Void, any Error>?
        var watchedDescriptor: Int32?
        var cancelHandlerCloseObserved = false

        do {
            let task = Task {
                try await self.awaitSessionIdentityOnRealEvent(
                    .generateUUIDv7(),
                    harness: harness,
                    backend: AlwaysAbsentSessionRestoreProbe(),
                    zmxDirectory: zmxDirectoryPath,
                    queue: fixture.testQueue,
                    directoryOpenFactSink: { descriptor in fixture.openSink("opened", descriptor) },
                    directoryCloseFactSink: { descriptor in fixture.closeSink("closed", descriptor) },
                    cancellationRequestedFactSink: { fixture.cancellationRequestedSink("cancelled", ()) }
                )
            }
            cancelledWaitTask = task

            let openedDescriptor = try await fixture.openRecorder.expectNext(
                in: "opened", where: { _ in true }, "directory open")
            watchedDescriptor = openedDescriptor
            #expect(fcntl(openedDescriptor, F_GETFD) != -1, "the descriptor must be open right after opening")

            let joinStep = HeldStep<Bool>("cancelled directory wait has unwound while its cancel handler is held")
            cancelledWaitJoinStep = joinStep
            let joinTask = Task {
                let wasCancelled: Bool
                do {
                    _ = try await task.value
                    wasCancelled = false
                } catch is CancellationError {
                    wasCancelled = true
                } catch {
                    wasCancelled = false
                }
                try await joinStep.arrive(wasCancelled)
            }
            cancelledWaitJoinTask = joinTask

            task.cancel()
            _ = try await fixture.cancellationRequestedRecorder.expectNext(
                in: "cancelled", where: { _ in true }, "cancellation requested")
            let wasCancelled = try await joinStep.firstArrival()
            #expect(wasCancelled, "the real-event wait must finish with CancellationError")
            #expect(
                fcntl(openedDescriptor, F_GETFD) != -1,
                "the descriptor must remain open after the cancelled wait has unwound")

            fixture.testQueue.resume()
            eventQueueIsSuspended = false
            let closedDescriptor = try await fixture.closeRecorder.expectNext(
                in: "closed", where: { _ in true }, "directory close")
            cancelHandlerCloseObserved = true
            #expect(
                closedDescriptor == openedDescriptor,
                "the cancel handler must close exactly the descriptor it owns")
            let statResult = fcntl(closedDescriptor, F_GETFD)
            let statErrno = errno
            #expect(statResult == -1)
            #expect(statErrno == EBADF, "an fcntl failure on a closed descriptor must be exactly EBADF")

            joinStep.release()
            try await joinTask.value
            return .success(())
        } catch {
            cancelledWaitTask?.cancel()
            if eventQueueIsSuspended {
                fixture.testQueue.resume()
                eventQueueIsSuspended = false
            }
            cancelledWaitJoinStep?.release()
            if let cancelledWaitTask {
                _ = try? await cancelledWaitTask.value
            }
            if let cancelledWaitJoinTask {
                try? await cancelledWaitJoinTask.value
            }
            if let watchedDescriptor, !cancelHandlerCloseObserved {
                _ = try? await fixture.closeRecorder.expectNext(
                    in: "closed", where: { $0 == watchedDescriptor }, "directory close during test cleanup")
                cancelHandlerCloseObserved = true
            }
            return .failure(error)
        }
    }

    /// Carries the real file descriptor number as its fact value, so this
    /// test can assert identity ("closed exactly the one it opened"), not
    /// merely "some open/close happened." Two separate `LocalFactSource`
    /// instances (one per call site above) rather than one shared source
    /// with two scopes, matching `ColdStartObserverTests.ScriptedSyscalls`'s
    /// own `directoryOpenCallFactSink`/`directoryCloseCallFactSink` pair.
    private static func fileDescriptorFactVocabulary() -> FactVocabulary<String, Int32> {
        FactVocabulary(
            describeScope: { $0 },
            describeFact: { "fd=\($0)" },
            isClosing: { _, _ in false }
        )
    }
}

/// Always reports the session's own socket endpoint as absent, so
/// `awaitSessionIdentityOnRealEvent` never resolves an identity on its own
/// -- every suspension inside it is this test's own cancellation, never a
/// real daemon settling. Matches the established `ZmxSessionRestoreProbing`
/// fake shape already used by `HeldZmxSessionRestoreProbe`
/// (`WorkspacePreparedContentMountCoordinatorRestoreProbeIndependenceTests.swift`).
private final class AlwaysAbsentSessionRestoreProbe: ZmxSessionRestoreProbing, @unchecked Sendable {
    func discoverSessionInventory() async -> ZmxSessionInventory { .complete([:]) }
    func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? { nil }
}
