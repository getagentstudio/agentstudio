import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer

@Suite("Bridge development seeded worktree observation", .serialized)
struct BridgeDevelopmentSeededWorktreeObservationTests {
    @Test("registration failure prevents readiness and leaves no registered worktree")
    func registrationFailurePreventsReadiness() async throws {
        // Arrange
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        fixture.fseventClient.setNextRegistrationOutcome(
            .unavailable(.streamStartFailed)
        )
        let observation = fixture.makeObservation()
        try await withSeededObservationCleanup(observation: observation, probe: fixture.probe) {

            // Act / Assert
            await #expect(
                throws: BridgeDevelopmentSeededWorktreeObservationError.registrationUnavailable(
                    .streamStartFailed
                )
            ) {
                try await observation.start()
            }
            #expect(fixture.fseventClient.registeredWorktreeIds.isEmpty)
            #expect(await fixture.bus.subscriberCount == 0)
            await observation.shutdown()
        }
    }

    @Test("production filesystem and Git actors route exact seeded-worktree invalidations")
    func productionActorsRouteExactSeededWorktreeInvalidations() async throws {
        // Arrange
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        let observation = fixture.makeObservation()
        try await withSeededObservationCleanup(observation: observation, probe: fixture.probe) {
            try await observation.start()
            _ = try await fixture.probe.nextStatus()
            await fixture.gitProvider.setBranch("feature/refreshed-observation-proof")

            // Act
            fixture.fseventClient.send(
                FSEventBatch(
                    worktreeId: fixture.source.worktreeID,
                    paths: [fixture.source.worktreeRoot.appending(path: "Sources/App.swift").path]
                )
            )
            let changeset = try await fixture.probe.nextFiles(paths: ["Sources/App.swift"])
            let status = try await fixture.probe.nextStatus(branch: "feature/refreshed-observation-proof")

            // Assert
            #expect(changeset.repoId == fixture.source.repoID)
            #expect(changeset.worktreeId == fixture.source.worktreeID)
            #expect(changeset.rootPath == fixture.source.worktreeRoot)
            #expect(changeset.paths == ["Sources/App.swift"])
            #expect(status.branch == "feature/refreshed-observation-proof")
            await observation.shutdown()
            #expect(fixture.fseventClient.unregisteredWorktreeIds == [fixture.source.worktreeID])
            #expect(await fixture.bus.subscriberCount == 0)
        }
    }

    @Test("router rejects unrelated repo worktree and root facts")
    func routerRejectsUnrelatedFacts() async throws {
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        let observation = fixture.makeObservation()
        try await withSeededObservationCleanup(observation: observation, probe: fixture.probe) {
            try await observation.start()
            _ = try await fixture.probe.nextStatus()
            await fixture.probe.beginRejectionWindow()
            let opening = await fixture.probe.facts.mark(.routingRejection)
            let foreign = fixture.source.worktreeRoot.appending(path: "foreign")
            await fixture.bus.post(fixture.fileEnvelope(path: "Sources/Foreign.swift", root: foreign, sequence: 90))
            await fixture.bus.post(fixture.statusEnvelope(branch: "foreign", root: foreign, sequence: 91))
            // The same ordered routing task reaches this valid marker only after both foreign envelopes.
            await fixture.bus.post(fixture.statusEnvelope(branch: "observation-routing-fence", sequence: 92))
            let isForeignInvalidation: @Sendable (SeededObservationFact) -> Bool = { fact in
                switch fact {
                case .filesChanged, .statusChanged: true
                default: false
                }
            }
            try await fixture.probe.facts.expectNone(
                of: isForeignInvalidation, "foreign invalidation", from: opening,
                closedBy: { if case .routingFence = $0 { true } else { false } }
            )
            await observation.shutdown()
        }
    }

    @Test("detected filesystem ingress completion stops fact admission")
    func detectedFilesystemIngressCompletionStopsFactAdmission() async throws {
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        let routingStep = HeldStep<Void>(
            "in-flight routing at source termination", cancellation: .holdThroughCancellation)
        defer { routingStep.release() }
        let observation = fixture.makeObservation(routingStep: routingStep)
        try await observation.start { terminal in await fixture.probe.recordTerminal(terminal) }
        _ = try await fixture.probe.nextStatus()
        await fixture.bus.post(fixture.fileEnvelope(path: "Sources/Held.swift", sequence: 91))
        _ = try await routingStep.firstArrival()
        let cancellationObserver = Task {
            try await routingStep.cancellationObserved()
            fixture.probe.facts.append(scope: .terminalOrder, fact: .routingCancelled)
        }
        do {
            fixture.fseventClient.shutdown()
            // An early terminal callback races into this recorder as a wrong fact, rather than passing a point read.
            _ = try await fixture.probe.facts.expectNext(
                in: .terminalOrder, where: { if case .routingCancelled = $0 { true } else { false } },
                "routing cancellation before terminal admission close"
            )
            await fixture.probe.beginAdmissionWindow()
            let opening = await fixture.probe.facts.mark(.admission)
            await fixture.bus.post(fixture.fileEnvelope(path: "Sources/Late.swift", sequence: 92))
            routingStep.release()
            try await fixture.probe.facts.expectNone(
                of: {
                    if case .filesChanged(let changeset) = $0 {
                        changeset.paths == ["Sources/Late.swift"]
                    } else {
                        false
                    }
                },
                "late canonical-root file admission", from: opening,
                closedBy: { if case .terminal(.eventsEnded) = $0 { true } else { false } }
            )
            try await cancellationObserver.value
            #expect(fixture.fseventClient.unregisteredWorktreeIds == [fixture.source.worktreeID])
            await observation.shutdown()
            await observation.shutdown()
            #expect(await fixture.bus.subscriberCount == 0)
            #expect(await fixture.probe.terminals == [.eventsEnded])
            try await fixture.probe.finish()
        } catch {
            routingStep.release()
            cancellationObserver.cancel()
            _ = try? await cancellationObserver.value
            await observation.shutdown()
            try? await fixture.probe.finish()
            throw error
        }
    }

    @Test("real Darwin observation routes a post-start Git worktree edit")
    func realDarwinObservationRoutesPostStartEdit() async throws {
        // Arrange
        let root = try await FilesystemTestGitRepo.create(
            named: "bridge-development-live-observation"
        )
        defer { FilesystemTestGitRepo.destroy(root) }
        let trackedFile = root.appending(path: "tracked.txt")
        try "initial\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: root, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: root, args: ["commit", "-m", "Initial"])
        let source = BridgeDevelopmentObservationFixture.makeSource(root: root)
        let probe = BridgeDevelopmentObservationProbe()
        let bus = EventBus<RuntimeEnvelope>(name: "BridgeDevelopmentRealObservation")
        let statusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let observation = BridgeDevelopmentSeededWorktreeObservation(
            source: source,
            dependencies: .init(
                bus: bus,
                fseventStreamClient: DarwinFSEventStreamClient(),
                gitWorkingTreeProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: statusPhysicalGate
                ),
                filesystemDebounceWindow: .milliseconds(10),
                filesystemMaximumFlushLatency: .milliseconds(25),
                gitCoalescingWindow: .milliseconds(10)
            ),
            invalidationSink: { invalidation in
                await probe.record(invalidation)
            }
        )
        try await withSeededObservationCleanup(observation: observation, probe: probe) {
            try await observation.start()
            _ = try await probe.nextStatus()

            // Act
            try "initial\nupdated\n".write(to: trackedFile, atomically: false, encoding: .utf8)
            let changeset = try await probe.nextFiles(paths: ["tracked.txt"])
            let status = try await probe.nextStatus()

            // Assert
            #expect(changeset.paths == ["tracked.txt"])
            #expect(status.summary.changed == 1)
            await observation.shutdown()
            #expect(await bus.subscriberCount == 0)
        }
    }

    @Test("real Darwin deletion emits a file invalidation and refreshes Review")
    func realDarwinDeletionEmitsInvalidationAndRefreshesReview() async throws {
        // Arrange
        let root = try await FilesystemTestGitRepo.create(
            named: "bridge-development-live-review"
        )
        defer { FilesystemTestGitRepo.destroy(root) }
        let trackedFile = root.appending(path: "tracked.txt")
        try "initial\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: root, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: root, args: ["commit", "-m", "Initial"])
        try "initial\nupdated\n".write(to: trackedFile, atomically: false, encoding: .utf8)
        let source = BridgeDevelopmentObservationFixture.makeSource(root: root)
        let probe = BridgeDevelopmentObservationProbe()
        let bus = EventBus<RuntimeEnvelope>(name: "BridgeDevelopmentRealDeletionObservation")
        let statusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let lifecycle = SeededReviewLifecycleRecorder()
        let host = try await makeReviewCommitObservedHost(
            source: source,
            statusPhysicalGate: statusPhysicalGate,
            lifecycle: lifecycle
        )
        let observation = BridgeDevelopmentSeededWorktreeObservation(
            source: source,
            dependencies: .init(
                bus: bus,
                fseventStreamClient: DarwinFSEventStreamClient(),
                gitWorkingTreeProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: statusPhysicalGate
                ),
                filesystemDebounceWindow: .milliseconds(10),
                filesystemMaximumFlushLatency: .milliseconds(25),
                gitCoalescingWindow: .milliseconds(10)
            ),
            invalidationSink: { invalidation in
                await host.handleObservedWorktreeInvalidation(invalidation)
                await probe.record(invalidation)
            }
        )
        do {
            _ = try await host.issueBootstrap(for: seededReviewBootstrapRequest())
            try await observation.start()
            #expect(await host.diagnosticCommittedReviewPublication()?.package.reviewGeneration == 1)
            _ = try await probe.nextStatus()
            _ = try await lifecycle.nextTerminal()
            let baselinePublication = try #require(
                await host.diagnosticCommittedReviewPublication()
            )
            #expect(baselinePublication.package.reviewGeneration == 1)
            #expect(
                baselinePublication.package.itemsById.values.contains {
                    $0.headPath == "tracked.txt"
                }
            )

            let deletionOpening = lifecycle.openDeletionObservation()

            // Act deletion as the only post-start filesystem mutation.
            try FileManager.default.removeItem(at: trackedFile)
            let deletionChangeset = try await probe.nextFiles(paths: ["tracked.txt"])
            #expect(deletionChangeset.paths == ["tracked.txt"])
            let deletedPublication = try await lifecycle.requireCommittedDeletion(
                path: "tracked.txt", after: deletionOpening)

            // Assert deletion.
            #expect(deletedPublication.package.reviewGeneration == baselinePublication.package.reviewGeneration)
            #expect(deletedPublication.package.revision > baselinePublication.package.revision)
            #expect(
                deletedPublication.package.itemsById.values.contains {
                    $0.basePath == "tracked.txt" && $0.headPath == nil
                }
            )
            await observation.stopFactAdmissionAndDrainRouting()
            await host.shutdown()
            await observation.shutdownSources()
            try await lifecycle.finish()
            try await probe.finish()
        } catch {
            await observation.stopFactAdmissionAndDrainRouting()
            await host.shutdown()
            await observation.shutdownSources()
            try await lifecycle.finish()
            try? await probe.finish()
            throw error
        }
    }

}
