import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation output coordinator")
struct WorktreeAnnotationOutputCoordinatorTests {
    @Test("generation failure occurs before prepare or effect")
    func generationFailureHasNoDurableOrExternalEffect() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .succeeded(destinationPath: nil))

        await #expect(throws: WorktreeAnnotationBatchProjectorError.invalidGeneratedContext) {
            try await fixture.coordinator.executeNew(
                fixture.request(worktreeLabel: "/absolute-path-is-not-generated-context"),
                productAdmission: try BridgeProductAdmissionTestContext.make().context)
        }
        #expect(await fixture.recorder.events.isEmpty)
    }

    @Test("prepare commits before effect and success finalizes afterward")
    func preparePrecedesEffectAndFinalization() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .succeeded(destinationPath: nil))

        let result = try await fixture.coordinator.executeNew(
            fixture.request(), productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .succeeded(let output) = result else {
            Issue.record("Expected successful output")
            return
        }
        #expect(output.attempt.state == .succeeded)
        #expect(await fixture.recorder.events == ["prepare", "effect", "finalize"])
    }

    @Test("a begun application-owned write still records success after operation cancellation")
    func begunWriteFinalizesAfterOperationCancellation() async throws {
        let effectGate = HeldStep<Void>("begun-output-effect", cancellation: .holdThroughCancellation)
        let fixture = makeCoordinatorFixture(
            effectOutcome: .succeeded(destinationPath: nil),
            effectGate: effectGate
        )
        let operation = Task {
            try await fixture.coordinator.executeNew(
                fixture.request(outputKind: .jsonFile),
                productAdmission: try BridgeProductAdmissionTestContext.make().context)
        }
        try await effectGate.firstArrival()

        operation.cancel()
        effectGate.release()

        guard case .succeeded(let output) = try await operation.value else {
            Issue.record("Expected known write success after cancellation")
            return
        }
        #expect(output.attempt.state == .succeeded)
        #expect(await fixture.recorder.events == ["choose-destination", "prepare", "effect", "finalize"])
    }

    @Test("JSON destination cancellation occurs before attempt preparation")
    func jsonDestinationCancellationCreatesNoAttemptOrHistory() async throws {
        let fixture = makeCoordinatorFixture(
            effectOutcome: .succeeded(destinationPath: nil),
            destinationOutcome: .cancelled
        )

        let result = try await fixture.coordinator.executeNew(
            fixture.request(outputKind: .jsonFile),
            productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .destinationCancelled = result else {
            Issue.record("Expected destination cancellation")
            return
        }
        #expect(await fixture.recorder.events == ["choose-destination"])
    }

    @Test("JSON destination is selected before prepare and used by the exact-byte effect")
    func jsonDestinationSelectionPrecedesPrepare() async throws {
        let fixture = makeCoordinatorFixture(
            effectOutcome: .succeeded(destinationPath: nil),
            destinationOutcome: .selected(path: "/tmp")
        )

        let result = try await fixture.coordinator.executeNew(
            fixture.request(outputKind: .jsonFile),
            productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .succeeded(let output) = result else {
            Issue.record("Expected successful JSON export")
            return
        }
        #expect(output.attempt.destinationPath?.contains("AgentStudio Review Comments") == true)
        #expect(await fixture.effect.lastRequest?.destinationPath == output.attempt.destinationPath)
        #expect(
            await fixture.recorder.events
                == ["choose-destination", "prepare", "effect", "finalize"]
        )
    }

    @Test("known effect failure cancels without finalization")
    func knownEffectFailureCancelsPreparedAttempt() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .failed("clipboard unavailable"))

        let result = try await fixture.coordinator.executeNew(
            fixture.request(), productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .effectFailed(let effectError, let effectCode, let output) = result else {
            Issue.record("Expected known effect failure")
            return
        }
        #expect(effectError == "clipboard unavailable")
        #expect(effectCode == nil)
        #expect(output.attempt.state == .cancelled)
        #expect(await fixture.recorder.events == ["prepare", "effect", "cancel"])
    }

    @Test("missing-folder failure retains a typed output code after attempt cleanup")
    func missingFolderFailureIsTypedAfterCleanup() async throws {
        let fixture = makeCoordinatorFixture(
            effectOutcome: .fileFailure(code: .missingFolder, message: "Folder missing")
        )

        let result = try await fixture.coordinator.executeNew(
            fixture.request(outputKind: .jsonFile),
            productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .effectFailed(let message, let code, let output) = result else {
            Issue.record("Expected typed export failure")
            return
        }
        #expect(message == "Folder missing")
        #expect(code == .missingFolder)
        #expect(output.attempt.state == .cancelled)
    }

    @Test("cancel persistence failure retains proof and retry performs cleanup only")
    func cancellationFailureRetriesCleanupWithoutReplayingEffect() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .failed("clipboard unavailable"))
        await fixture.store.setCancelFailureEnabled(true)
        let result = try await fixture.coordinator.executeNew(
            fixture.request(), productAdmission: try BridgeProductAdmissionTestContext.make().context)
        guard case .effectAndCleanupFailed(let output, let effectError, _, let cleanupError) = result else {
            Issue.record("Expected effect plus cleanup failure")
            return
        }
        #expect(effectError == "clipboard unavailable")
        #expect(cleanupError == "forcedFailure")

        await fixture.store.setCancelFailureEnabled(false)
        let cancelled = try await fixture.coordinator.retryCancellationCleanup(
            attemptID: output.attempt.id
        )

        #expect(cancelled.attempt.state == .cancelled)
        #expect(await fixture.recorder.events == ["prepare", "effect", "cancel", "cancel"])
        await #expect(throws: WorktreeAnnotationOutputCoordinatorError.cleanupProofUnavailable) {
            try await fixture.coordinator.retryCancellationCleanup(attemptID: output.attempt.id)
        }
    }

    @Test("known success with finalization failure is partial success and records the state")
    func finalizationFailureNeverReplaysKnownSuccess() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .succeeded(destinationPath: nil))
        await fixture.store.setFinalizeFailureEnabled(true)

        let result = try await fixture.coordinator.executeNew(
            fixture.request(), productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .partialSuccess(let output, let finalizationError) = result else {
            Issue.record("Expected partial success")
            return
        }
        #expect(output.attempt.state == .finalizationFailed)
        #expect(finalizationError == "forcedFailure")
        #expect(await fixture.recorder.events == ["prepare", "effect", "finalize", "mark-finalization-failed"])
    }

    @Test("a known write keeps its collision-resolved path when finalization fails")
    func partialSuccessRecordsActualCollisionResolvedPath() async throws {
        let fixture = makeCoordinatorFixture(
            effectOutcome: .succeeded(destinationPath: "/tmp/AgentStudio Review Comments-2.json")
        )
        await fixture.store.setFinalizeFailureEnabled(true)

        let result = try await fixture.coordinator.executeNew(
            fixture.request(outputKind: .jsonFile),
            productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .partialSuccess(let output, _) = result else {
            Issue.record("Expected known write with failed finalization")
            return
        }
        #expect(output.attempt.destinationPath == "/tmp/AgentStudio Review Comments-2.json")
        #expect(output.attempt.state == .finalizationFailed)
    }

    @Test("startup recovery marks a retained prepared attempt unknown without replay")
    func preparedAttemptRecoversUnknownWithoutAutomaticReplay() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .failed("clipboard unavailable"))
        await fixture.store.setCancelFailureEnabled(true)

        let result = try await fixture.coordinator.executeNew(
            fixture.request(), productAdmission: try BridgeProductAdmissionTestContext.make().context)
        guard case .effectAndCleanupFailed(let output, _, _, _) = result else {
            Issue.record("Expected retained prepared output")
            return
        }
        #expect(await fixture.store.state(attemptID: output.attempt.id) == .prepared)

        await fixture.store.setCancelFailureEnabled(false)
        #expect(try await fixture.coordinator.recoverPreparedAttemptsAsUnknown() == 1)
        #expect(await fixture.store.state(attemptID: output.attempt.id) == .unknown)
        #expect(await fixture.recorder.events == ["prepare", "effect", "cancel", "recover-unknown"])
    }

    @Test("explicit repetition sends only persisted exact bytes and membership")
    func explicitRepetitionUsesPersistedExactOutput() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .succeeded(destinationPath: nil))
        let sourceAttemptID = WorktreeAnnotationOutputAttemptID(rawValue: outputCoordinatorTestUUID(90))
        let persistedBytes = Data("persisted exact bytes; do not rebuild".utf8)
        await fixture.store.installRepeatSource(
            attemptID: sourceAttemptID,
            snapshot: fixture.snapshot,
            exactBytes: persistedBytes
        )

        let result = try await fixture.coordinator.executeRepeat(
            sourceAttemptID: sourceAttemptID, productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .succeeded = result else {
            Issue.record("Expected successful repetition")
            return
        }
        #expect(await fixture.effect.lastRequest?.exactBytes == persistedBytes)
        #expect(await fixture.recorder.events == ["repeat", "effect", "finalize"])
    }

    @Test("JSON repetition rewrites its recorded file with persisted exact bytes")
    func jsonRepetitionUsesRecordedDestinationWithoutRebuildingOutput() async throws {
        let fixture = makeCoordinatorFixture(effectOutcome: .succeeded(destinationPath: nil))
        let sourceAttemptID = WorktreeAnnotationOutputAttemptID(rawValue: outputCoordinatorTestUUID(91))
        let persistedBytes = Data("{\"persisted\":true}".utf8)
        await fixture.store.installRepeatSource(
            attemptID: sourceAttemptID,
            outputKind: .jsonFile,
            snapshot: fixture.snapshot,
            exactBytes: persistedBytes,
            destinationPath: "/tmp/first-export.json"
        )

        let result = try await fixture.coordinator.executeRepeat(
            sourceAttemptID: sourceAttemptID, productAdmission: try BridgeProductAdmissionTestContext.make().context)

        guard case .succeeded(let output) = result else {
            Issue.record("Expected successful JSON repetition")
            return
        }
        #expect(output.attempt.destinationPath == "/tmp/first-export.json")
        #expect(await fixture.effect.lastRequest?.destinationPath == "/tmp/first-export.json")
        #expect(await fixture.effect.lastRequest?.exactBytes == persistedBytes)
    }
}

private struct OutputCoordinatorFixture {
    let coordinator: WorktreeAnnotationOutputCoordinatorActor
    let store: TestOutputStore
    let effect: TestOutputEffect
    let recorder: OutputSequenceRecorder
    let detail: WorktreeAnnotationSessionDetail
    let selection: WorktreeAnnotationSQLiteRepository.OutputMessageSelection
    let snapshot: WorktreeAnnotationBatchSnapshotV2

    func request(
        outputKind: WorktreeAnnotationOutputKind = .clipboardMarkdown,
        worktreeLabel: String = "agent-studio.review-comments"
    ) -> WorktreeAnnotationOutputRequest {
        .init(
            outputKind: outputKind,
            destination: outputKind == .jsonFile ? .choose : nil,
            sessionDetail: detail,
            selectedMessages: [selection],
            placementsByThreadID: [
                detail.threads[0].thread.id: .init(
                    placement: .exact,
                    currentPath: "Sources/Feature.swift",
                    currentStartLine: 1,
                    currentEndLine: 1,
                    currentSourceIdentity: "source-1"
                )
            ],
            sessionLabel: "Current review",
            worktreeLabel: worktreeLabel,
            comparisonLabel: nil
        )
    }
}

private func makeCoordinatorFixture(
    effectOutcome: WorktreeAnnotationOutputEffectOutcome,
    effectGate: HeldStep<Void>? = nil,
    destinationOutcome: WorktreeAnnotationOutputDestinationOutcome = .selected(
        path: "/tmp/default-review-comments.json"
    )
) -> OutputCoordinatorFixture {
    let recorder = OutputSequenceRecorder()
    let store = TestOutputStore(recorder: recorder)
    let effect = TestOutputEffect(
        recorder: recorder,
        destinationOutcome: destinationOutcome,
        outcome: effectOutcome,
        effectGate: effectGate
    )
    let sessionID = WorktreeAnnotationSessionID(rawValue: outputCoordinatorTestUUID(1))
    let threadID = WorktreeAnnotationThreadID(rawValue: outputCoordinatorTestUUID(2))
    let messageID = WorktreeAnnotationMessageID(rawValue: outputCoordinatorTestUUID(3))
    let detail = makeCoordinatorSessionDetail(
        sessionID: sessionID,
        threadID: threadID,
        messageID: messageID
    )
    let selection = WorktreeAnnotationSQLiteRepository.OutputMessageSelection(
        messageID: messageID,
        expectedSavedRevision: 1
    )
    let snapshot = makeCoordinatorSnapshot(
        detail: detail,
        selection: selection,
        threadID: threadID
    )
    let attemptIDs = OutputAttemptIDSequence(startingAt: 10)
    return OutputCoordinatorFixture(
        coordinator: WorktreeAnnotationOutputCoordinatorActor(
            store: store,
            effect: effect,
            now: { Date(timeIntervalSince1970: 10) },
            generateAttemptID: { await attemptIDs.next() }
        ),
        store: store,
        effect: effect,
        recorder: recorder,
        detail: detail,
        selection: selection,
        snapshot: snapshot
    )
}

private func makeCoordinatorSessionDetail(
    sessionID: WorktreeAnnotationSessionID,
    threadID: WorktreeAnnotationThreadID,
    messageID: WorktreeAnnotationMessageID
) -> WorktreeAnnotationSessionDetail {
    WorktreeAnnotationSessionDetail(
        session: .init(
            id: sessionID,
            repositoryID: "repository-1",
            worktreeID: "worktree-1",
            lifecycle: .living,
            sourceRelationship: .applicable,
            acceptedSourceFingerprint: .init(
                repositoryID: "repository-1",
                worktreeID: "worktree-1",
                fileSourceIdentity: "source-1",
                reviewComparisonOrigin: nil
            ),
            semanticRevision: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            completedAt: nil
        ),
        threads: [
            .init(
                thread: .init(
                    id: threadID,
                    sessionID: sessionID,
                    origin: .located(
                        .init(
                            repositoryRelativePath: "Sources/Feature.swift",
                            startLine: 1,
                            endLine: 1,
                            sourceRole: .file,
                            diffSide: nil,
                            sourceIdentity: "source-1",
                            selectedExcerpt: "let value = 1",
                            contextBefore: nil,
                            contextAfter: nil
                        )
                    ),
                    resolution: .open,
                    createdOrdinal: 0,
                    semanticRevision: 0,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 1),
                    resolvedAt: nil
                ),
                messages: [
                    .init(
                        id: messageID,
                        threadID: threadID,
                        ordinal: 0,
                        semanticRevision: 1,
                        createdAt: Date(timeIntervalSince1970: 1),
                        updatedAt: Date(timeIntervalSince1970: 1),
                        savedBody: "Preserve behavior",
                        savedRevision: 1,
                        draft: nil,
                        handled: false,
                        status: .editable
                    )
                ]
            )
        ]
    )
}

private func makeCoordinatorSnapshot(
    detail: WorktreeAnnotationSessionDetail,
    selection: WorktreeAnnotationSQLiteRepository.OutputMessageSelection,
    threadID: WorktreeAnnotationThreadID
) -> WorktreeAnnotationBatchSnapshotV2 {
    let initialAttemptID = WorktreeAnnotationOutputAttemptID(rawValue: outputCoordinatorTestUUID(10))
    return try! WorktreeAnnotationBatchProjector.makeSnapshot(
        .init(
            batchID: initialAttemptID,
            createdAt: Date(timeIntervalSince1970: 10),
            sessionDetail: detail,
            selectedMessages: [selection],
            placementsByThreadID: [
                threadID: .init(
                    placement: .exact,
                    currentPath: "Sources/Feature.swift",
                    currentStartLine: 1,
                    currentEndLine: 1,
                    currentSourceIdentity: "source-1"
                )
            ],
            sessionLabel: "Current review",
            worktreeLabel: "agent-studio.review-comments",
            comparisonLabel: nil
        )
    )
}

private actor OutputSequenceRecorder {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor OutputAttemptIDSequence {
    private var suffix: Int

    init(startingAt suffix: Int) {
        self.suffix = suffix
    }

    func next() -> WorktreeAnnotationOutputAttemptID {
        defer { suffix += 1 }
        return .init(rawValue: outputCoordinatorTestUUID(suffix))
    }
}

private enum TestOutputFailure: Error {
    case forcedFailure
}

private actor TestOutputStore: WorktreeAnnotationOutputServiceAccess {
    private let recorder: OutputSequenceRecorder
    private var outputsByAttemptID:
        [WorktreeAnnotationOutputAttemptID: WorktreeAnnotationSQLiteRepository.PreparedOutput] = [:]
    private var cancelFailureEnabled = false
    private var finalizeFailureEnabled = false

    init(recorder: OutputSequenceRecorder) {
        self.recorder = recorder
    }

    func setCancelFailureEnabled(_ enabled: Bool) {
        cancelFailureEnabled = enabled
    }

    func setFinalizeFailureEnabled(_ enabled: Bool) {
        finalizeFailureEnabled = enabled
    }

    func prepareOutput(
        _ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        await recorder.append("prepare")
        let output = preparedOutput(
            .init(
                attemptID: props.attemptID,
                outputKind: props.outputKind,
                snapshot: props.canonicalSnapshot,
                exactBytes: props.exactBytes,
                destinationPath: props.destinationPath,
                repeatedFromAttemptID: nil,
                state: .prepared
            )
        )
        outputsByAttemptID[props.attemptID] = output
        return output
    }

    func repeatOutputAttempt(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        repeatedAttemptID: WorktreeAnnotationOutputAttemptID,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        _ = now
        await recorder.append("repeat")
        let source = try requiredOutput(sourceAttemptID)
        let output = WorktreeAnnotationSQLiteRepository.PreparedOutput(
            attempt: .init(
                id: repeatedAttemptID,
                sessionID: source.attempt.sessionID,
                outputKind: source.attempt.outputKind,
                state: .prepared,
                formatVersion: source.attempt.formatVersion,
                contentType: source.attempt.contentType,
                exactBytes: source.attempt.exactBytes,
                destinationPath: destinationPath,
                repeatedFromAttemptID: sourceAttemptID,
                effectError: nil,
                cleanupError: nil,
                createdAt: now,
                updatedAt: now
            ),
            canonicalSnapshot: source.canonicalSnapshot,
            memberships: source.memberships,
            event: nil
        )
        outputsByAttemptID[repeatedAttemptID] = output
        return output
    }

    func inspectOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID
    ) throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        try requiredOutput(attemptID)
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        _ = (effectError, now)
        await recorder.append("cancel")
        if cancelFailureEnabled { throw TestOutputFailure.forcedFailure }
        let output = try requiredOutput(attemptID).replacing(state: .cancelled, effectError: effectError)
        outputsByAttemptID[attemptID] = output
        return output
    }

    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        _ = (eventKind, now)
        await recorder.append("finalize")
        if finalizeFailureEnabled { throw TestOutputFailure.forcedFailure }
        let output = try requiredOutput(attemptID).replacing(
            state: .succeeded,
            destinationPath: destinationPath
        )
        outputsByAttemptID[attemptID] = output
        return output
    }

    func markOutputAttemptFinalizationFailed(
        attemptID: WorktreeAnnotationOutputAttemptID,
        cleanupError: String,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        _ = (cleanupError, now)
        await recorder.append("mark-finalization-failed")
        let output = try requiredOutput(attemptID).replacing(
            state: .finalizationFailed,
            destinationPath: destinationPath,
            cleanupError: cleanupError
        )
        outputsByAttemptID[attemptID] = output
        return output
    }

    func markPreparedOutputAttemptsUnknown(now: Date) async throws -> Int {
        _ = now
        await recorder.append("recover-unknown")
        var changedCount = 0
        for (attemptID, output) in outputsByAttemptID where output.attempt.state == .prepared {
            outputsByAttemptID[attemptID] = output.replacing(state: .unknown)
            changedCount += 1
        }
        return changedCount
    }

    func state(attemptID: WorktreeAnnotationOutputAttemptID) -> WorktreeAnnotationOutputAttemptState? {
        outputsByAttemptID[attemptID]?.attempt.state
    }

    func installRepeatSource(
        attemptID: WorktreeAnnotationOutputAttemptID,
        outputKind: WorktreeAnnotationOutputKind = .clipboardMarkdown,
        snapshot: WorktreeAnnotationBatchSnapshotV2,
        exactBytes: Data,
        destinationPath: String? = nil
    ) {
        outputsByAttemptID[attemptID] = preparedOutput(
            .init(
                attemptID: attemptID,
                outputKind: outputKind,
                snapshot: snapshot,
                exactBytes: exactBytes,
                destinationPath: destinationPath,
                repeatedFromAttemptID: nil,
                state: .unknown
            )
        )
    }

    private func requiredOutput(
        _ attemptID: WorktreeAnnotationOutputAttemptID
    ) throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        guard let output = outputsByAttemptID[attemptID] else {
            throw WorktreeAnnotationRepositoryError.notFound
        }
        return output
    }
}

private actor TestOutputEffect: WorktreeAnnotationOutputEffect {
    private let recorder: OutputSequenceRecorder
    private let destinationOutcome: WorktreeAnnotationOutputDestinationOutcome
    private let outcome: WorktreeAnnotationOutputEffectOutcome
    private let effectGate: HeldStep<Void>?
    private(set) var lastRequest: WorktreeAnnotationOutputEffectRequest?

    init(
        recorder: OutputSequenceRecorder,
        destinationOutcome: WorktreeAnnotationOutputDestinationOutcome,
        outcome: WorktreeAnnotationOutputEffectOutcome,
        effectGate: HeldStep<Void>?
    ) {
        self.recorder = recorder
        self.destinationOutcome = destinationOutcome
        self.outcome = outcome
        self.effectGate = effectGate
    }

    func rememberedJSONFolder() async -> String {
        if case .selected(let path) = destinationOutcome { return path }
        return "/tmp"
    }

    func chooseJSONDestination(productAdmission: BridgeProductAdmissionContext) async
        -> WorktreeAnnotationOutputDestinationOutcome
    {
        await recorder.append("choose-destination")
        return destinationOutcome
    }

    func revealJSONFile(path: String, productAdmission: BridgeProductAdmissionContext) async -> Bool {
        _ = path
        return true
    }

    func perform(
        _ request: WorktreeAnnotationOutputEffectRequest
    ) async -> WorktreeAnnotationOutputEffectOutcome {
        lastRequest = request
        await recorder.append("effect")
        if let effectGate { try? await effectGate.arrive(()) }
        if case .succeeded(let destinationPath) = outcome {
            return .succeeded(destinationPath: destinationPath ?? request.destinationPath)
        }
        return outcome
    }
}

private struct PreparedOutputProps {
    let attemptID: WorktreeAnnotationOutputAttemptID
    let outputKind: WorktreeAnnotationOutputKind
    let snapshot: WorktreeAnnotationBatchSnapshotV2
    let exactBytes: Data
    let destinationPath: String?
    let repeatedFromAttemptID: WorktreeAnnotationOutputAttemptID?
    let state: WorktreeAnnotationOutputAttemptState
}

private func preparedOutput(_ props: PreparedOutputProps) -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
    .init(
        attempt: .init(
            id: props.attemptID,
            sessionID: props.snapshot.session.sessionID,
            outputKind: props.outputKind,
            state: props.state,
            formatVersion: props.snapshot.formatVersion,
            contentType: props.outputKind == .clipboardMarkdown
                ? "text/markdown; charset=utf-8"
                : "application/json; charset=utf-8",
            exactBytes: props.exactBytes,
            destinationPath: props.destinationPath,
            repeatedFromAttemptID: props.repeatedFromAttemptID,
            effectError: nil,
            cleanupError: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        ),
        canonicalSnapshot: .v2(props.snapshot),
        memberships: props.snapshot.entries.map {
            .init(
                messageID: $0.messageID,
                expectedSavedRevision: $0.savedRevision,
                batchOrdinal: $0.batchOrdinal
            )
        },
        event: nil
    )
}

extension WorktreeAnnotationSQLiteRepository.PreparedOutput {
    fileprivate func replacing(
        state: WorktreeAnnotationOutputAttemptState,
        destinationPath: String? = nil,
        effectError: String? = nil,
        cleanupError: String? = nil
    ) -> Self {
        .init(
            attempt: .init(
                id: attempt.id,
                sessionID: attempt.sessionID,
                outputKind: attempt.outputKind,
                state: state,
                formatVersion: attempt.formatVersion,
                contentType: attempt.contentType,
                exactBytes: attempt.exactBytes,
                destinationPath: destinationPath ?? attempt.destinationPath,
                repeatedFromAttemptID: attempt.repeatedFromAttemptID,
                effectError: effectError ?? attempt.effectError,
                cleanupError: cleanupError ?? attempt.cleanupError,
                createdAt: attempt.createdAt,
                updatedAt: attempt.updatedAt
            ),
            canonicalSnapshot: canonicalSnapshot,
            memberships: memberships,
            event: event
        )
    }
}

private func outputCoordinatorTestUUID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", suffix))!
}
