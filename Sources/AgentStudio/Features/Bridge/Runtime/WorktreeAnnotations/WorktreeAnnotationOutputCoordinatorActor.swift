import Foundation

protocol WorktreeAnnotationOutputServiceAccess: Sendable {
    func prepareOutput(
        _ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    func inspectOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    func repeatOutputAttempt(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        repeatedAttemptID: WorktreeAnnotationOutputAttemptID,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        effectError: String,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    func markOutputAttemptFinalizationFailed(
        attemptID: WorktreeAnnotationOutputAttemptID,
        cleanupError: String,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    func markPreparedOutputAttemptsUnknown(now: Date) async throws -> Int
}

struct WorktreeAnnotationOutputRequest: Sendable {
    let outputKind: WorktreeAnnotationOutputKind
    let destination: BridgeProductWorktreeAnnotationOperation.OutputDestination?
    let sessionDetail: WorktreeAnnotationSessionDetail
    let selectedMessages: [WorktreeAnnotationSQLiteRepository.OutputMessageSelection]
    let placementsByThreadID: [WorktreeAnnotationThreadID: WorktreeAnnotationThreadPlacementProjection]
    let sessionLabel: String
    let worktreeLabel: String
    let comparisonLabel: String?
    let expectedSessionRevision: Int
    let expectedProjectionRevision: Int

    init(
        outputKind: WorktreeAnnotationOutputKind,
        destination: BridgeProductWorktreeAnnotationOperation.OutputDestination? = nil,
        sessionDetail: WorktreeAnnotationSessionDetail,
        selectedMessages: [WorktreeAnnotationSQLiteRepository.OutputMessageSelection],
        placementsByThreadID: [WorktreeAnnotationThreadID: WorktreeAnnotationThreadPlacementProjection],
        sessionLabel: String,
        worktreeLabel: String,
        comparisonLabel: String?,
        expectedSessionRevision: Int = 0,
        expectedProjectionRevision: Int = 0
    ) {
        self.outputKind = outputKind
        self.destination = destination
        self.sessionDetail = sessionDetail
        self.selectedMessages = selectedMessages
        self.placementsByThreadID = placementsByThreadID
        self.sessionLabel = sessionLabel
        self.worktreeLabel = worktreeLabel
        self.comparisonLabel = comparisonLabel
        self.expectedSessionRevision = expectedSessionRevision
        self.expectedProjectionRevision = expectedProjectionRevision
    }
}

struct WorktreeAnnotationOutputLabels: Equatable, Sendable {
    let sessionLabel: String
    let worktreeLabel: String
    let comparisonLabel: String?
}

struct WorktreeAnnotationOutputResultSummary: Equatable, Sendable {
    let attemptID: WorktreeAnnotationOutputAttemptID
    let sessionID: WorktreeAnnotationSessionID
    let outputKind: WorktreeAnnotationOutputKind
    let messageCount: Int
    let destinationFilename: String?

    init(_ output: WorktreeAnnotationSQLiteRepository.PreparedOutput) {
        attemptID = output.attempt.id
        sessionID = output.attempt.sessionID
        outputKind = output.attempt.outputKind
        messageCount = output.memberships.count
        destinationFilename = output.attempt.destinationPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }
}

enum WorktreeAnnotationOutputCommandOutcome: Equatable, Sendable {
    case destinationCancelled
    case destinationSelectionFailed(String)
    case succeeded(WorktreeAnnotationOutputResultSummary)
    case effectFailed(
        summary: WorktreeAnnotationOutputResultSummary,
        effectError: String,
        effectCode: WorktreeAnnotationOutputFileFailureCode?
    )
    case effectAndCleanupFailed(
        summary: WorktreeAnnotationOutputResultSummary,
        effectError: String,
        effectCode: WorktreeAnnotationOutputFileFailureCode?,
        cleanupError: String
    )
    case partialSuccess(summary: WorktreeAnnotationOutputResultSummary, finalizationError: String)

    var summary: WorktreeAnnotationOutputResultSummary? {
        switch self {
        case .destinationCancelled, .destinationSelectionFailed:
            nil
        case .succeeded(let summary):
            summary
        case .effectFailed(let summary, _, _),
            .effectAndCleanupFailed(let summary, _, _, _),
            .partialSuccess(let summary, _):
            summary
        }
    }
}

package enum WorktreeAnnotationOutputEffectKind: Equatable, Sendable {
    case clipboardMarkdown
    case jsonFile
}

package struct WorktreeAnnotationOutputEffectRequest: Equatable, Sendable {
    package let productAdmission: BridgeProductAdmissionContext
    package let attemptID: UUID
    package let outputKind: WorktreeAnnotationOutputEffectKind
    package let contentType: String
    package let exactBytes: Data
    package let destinationPath: String?
    package let suggestedFilename: String?

    package init(
        productAdmission: BridgeProductAdmissionContext,
        attemptID: UUID,
        outputKind: WorktreeAnnotationOutputEffectKind,
        contentType: String,
        exactBytes: Data,
        destinationPath: String?,
        suggestedFilename: String? = nil
    ) {
        self.productAdmission = productAdmission
        self.attemptID = attemptID
        self.outputKind = outputKind
        self.contentType = contentType
        self.exactBytes = exactBytes
        self.destinationPath = destinationPath
        self.suggestedFilename = suggestedFilename
    }
}

package enum WorktreeAnnotationOutputEffectOutcome: Equatable, Sendable {
    case succeeded(destinationPath: String?)
    case cancelled
    case fileFailure(code: WorktreeAnnotationOutputFileFailureCode, message: String)
    case failed(String)
}

package enum WorktreeAnnotationOutputFileFailureCode: String, Codable, Equatable, Sendable {
    case missingFolder = "missing_folder"
    case permissionDenied = "permission_denied"
}

package enum WorktreeAnnotationOutputDestinationOutcome: Equatable, Sendable {
    case selected(path: String)
    case cancelled
    case failed(String)
}

package protocol WorktreeAnnotationOutputEffect: Sendable {
    func rememberedJSONFolder() async -> String
    func chooseJSONDestination(productAdmission: BridgeProductAdmissionContext) async
        -> WorktreeAnnotationOutputDestinationOutcome
    func revealJSONFile(path: String, productAdmission: BridgeProductAdmissionContext) async -> Bool

    func perform(
        _ request: WorktreeAnnotationOutputEffectRequest
    ) async -> WorktreeAnnotationOutputEffectOutcome
}

enum WorktreeAnnotationOutputExecutionResult: Equatable, Sendable {
    case destinationCancelled
    case destinationSelectionFailed(String)
    case succeeded(WorktreeAnnotationSQLiteRepository.PreparedOutput)
    case effectFailed(
        effectError: String,
        effectCode: WorktreeAnnotationOutputFileFailureCode?,
        output: WorktreeAnnotationSQLiteRepository.PreparedOutput
    )
    case effectAndCleanupFailed(
        output: WorktreeAnnotationSQLiteRepository.PreparedOutput,
        effectError: String,
        effectCode: WorktreeAnnotationOutputFileFailureCode?,
        cleanupError: String
    )
    case partialSuccess(
        output: WorktreeAnnotationSQLiteRepository.PreparedOutput,
        finalizationError: String
    )

    var commandOutcome: WorktreeAnnotationOutputCommandOutcome {
        switch self {
        case .destinationCancelled:
            .destinationCancelled
        case .destinationSelectionFailed(let error):
            .destinationSelectionFailed(error)
        case .succeeded(let output):
            .succeeded(.init(output))
        case .effectFailed(let effectError, let effectCode, let output):
            .effectFailed(summary: .init(output), effectError: effectError, effectCode: effectCode)
        case .effectAndCleanupFailed(let output, let effectError, let effectCode, let cleanupError):
            .effectAndCleanupFailed(
                summary: .init(output),
                effectError: effectError,
                effectCode: effectCode,
                cleanupError: cleanupError
            )
        case .partialSuccess(let output, let finalizationError):
            .partialSuccess(summary: .init(output), finalizationError: finalizationError)
        }
    }
}

enum WorktreeAnnotationOutputCoordinatorError: Error, Equatable, Sendable {
    case cleanupProofUnavailable
    case invalidDestination
}

package actor WorktreeAnnotationOutputCoordinatorActor {
    typealias NowProvider = @Sendable () -> Date
    typealias AttemptIDProvider = @Sendable () async -> WorktreeAnnotationOutputAttemptID

    private struct CancellationProof: Sendable {
        let effectError: String
    }

    private struct MaterializedOutput: Sendable {
        let snapshot: WorktreeAnnotationBatchSnapshotV2
        let exactBytes: Data
        let contentType: String
        let markdownPresentation: WorktreeAnnotationMarkdownPresentationContext?
    }

    private let store: any WorktreeAnnotationOutputServiceAccess
    private let effect: any WorktreeAnnotationOutputEffect
    private let now: NowProvider
    private let generateAttemptID: AttemptIDProvider
    private var cancellationProofByAttemptID: [WorktreeAnnotationOutputAttemptID: CancellationProof] = [:]

    init(
        store: any WorktreeAnnotationOutputServiceAccess,
        effect: any WorktreeAnnotationOutputEffect,
        now: @escaping NowProvider = Date.init,
        generateAttemptID: @escaping AttemptIDProvider = {
            WorktreeAnnotationOutputAttemptID.generate()
        }
    ) {
        self.store = store
        self.effect = effect
        self.now = now
        self.generateAttemptID = generateAttemptID
    }

    package init(
        store: WorktreeAnnotationServiceActor,
        effect: any WorktreeAnnotationOutputEffect
    ) {
        self.store = store
        self.effect = effect
        now = Date.init
        generateAttemptID = {
            WorktreeAnnotationOutputAttemptID.generate()
        }
    }

    func changeFolder(productAdmission: BridgeProductAdmissionContext) async
        -> WorktreeAnnotationOutputDestinationOutcome
    {
        await effect.chooseJSONDestination(productAdmission: productAdmission)
    }

    func revealSavedFile(path: String, productAdmission: BridgeProductAdmissionContext) async -> Bool {
        await effect.revealJSONFile(path: path, productAdmission: productAdmission)
    }

    func executeNew(
        _ request: WorktreeAnnotationOutputRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationOutputExecutionResult {
        let destinationResolution = await resolveDestination(
            outputKind: request.outputKind,
            destination: request.destination,
            productAdmission: productAdmission
        )
        let destinationPath: String?
        switch destinationResolution {
        case .resolved(let path):
            destinationPath = path
        case .cancelled:
            return .destinationCancelled
        case .failed(let error):
            return .destinationSelectionFailed(error)
        }
        guard !Task.isCancelled else { return .destinationCancelled }
        let createdAt = now()
        let timestamp = ISO8601DateFormatter().string(from: createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let suggestedFilename = "AgentStudio Review Comments \(timestamp).json"
        let preparedDestinationPath = destinationPath.map { folderPath in
            URL(fileURLWithPath: folderPath, isDirectory: true)
                .appendingPathComponent(suggestedFilename).path
        }
        let attemptID = await generateAttemptID()
        let materialization = try await Self.materialize(
            request: request,
            attemptID: attemptID,
            createdAt: createdAt
        )
        let orderedSelection = materialization.snapshot.entries.map {
            WorktreeAnnotationSQLiteRepository.OutputMessageSelection(
                messageID: $0.messageID,
                expectedSavedRevision: $0.savedRevision
            )
        }
        let prepared = try await store.prepareOutput(
            .init(
                attemptID: attemptID,
                sessionID: request.sessionDetail.session.id,
                outputKind: request.outputKind,
                formatVersion: materialization.snapshot.formatVersion,
                contentType: materialization.contentType,
                canonicalSnapshot: materialization.snapshot,
                exactBytes: materialization.exactBytes,
                markdownPresentation: materialization.markdownPresentation,
                destinationPath: preparedDestinationPath,
                repeatedFromAttemptID: nil,
                selectedMessages: orderedSelection,
                expectedSessionRevision: request.expectedSessionRevision,
                expectedProjectionRevision: request.expectedProjectionRevision,
                now: createdAt
            )
        )
        return await performEffect(
            for: prepared,
            productAdmission: productAdmission,
            suggestedFilename: request.outputKind == .jsonFile ? suggestedFilename : nil
        )
    }

    func executeRepeat(
        sourceAttemptID: WorktreeAnnotationOutputAttemptID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationOutputExecutionResult {
        let source = try await store.inspectOutputAttempt(attemptID: sourceAttemptID)
        // Repeat deliberately rewrites the recorded file, using its exact bytes.
        let destinationPath = source.attempt.destinationPath
        let repeated = try await store.repeatOutputAttempt(
            sourceAttemptID: sourceAttemptID,
            repeatedAttemptID: await generateAttemptID(),
            destinationPath: destinationPath,
            now: now()
        )
        return await performEffect(for: repeated, productAdmission: productAdmission)
    }

    func retryCancellationCleanup(
        attemptID: WorktreeAnnotationOutputAttemptID
    ) async throws -> WorktreeAnnotationSQLiteRepository.PreparedOutput {
        guard let proof = cancellationProofByAttemptID[attemptID] else {
            throw WorktreeAnnotationOutputCoordinatorError.cleanupProofUnavailable
        }
        let cancelled = try await store.cancelOutputAttempt(
            attemptID: attemptID,
            effectError: proof.effectError,
            now: now()
        )
        cancellationProofByAttemptID.removeValue(forKey: attemptID)
        return cancelled
    }

    package func recoverPreparedAttemptsAsUnknown() async throws -> Int {
        cancellationProofByAttemptID.removeAll()
        return try await store.markPreparedOutputAttemptsUnknown(now: now())
    }

    private func performEffect(
        for prepared: WorktreeAnnotationSQLiteRepository.PreparedOutput,
        productAdmission: BridgeProductAdmissionContext,
        suggestedFilename: String? = nil
    ) async -> WorktreeAnnotationOutputExecutionResult {
        let outcome = await effect.perform(
            .init(
                productAdmission: productAdmission,
                attemptID: prepared.attempt.id.rawValue,
                outputKind: prepared.attempt.outputKind == .clipboardMarkdown
                    ? .clipboardMarkdown
                    : .jsonFile,
                contentType: prepared.attempt.contentType,
                exactBytes: prepared.attempt.exactBytes,
                destinationPath: prepared.attempt.destinationPath,
                suggestedFilename: suggestedFilename
            )
        )
        switch outcome {
        case .succeeded(let destinationPath):
            return await finalizeKnownSuccess(prepared, destinationPath: destinationPath)
        case .cancelled:
            _ = await cancelKnownFailure(prepared, effectError: "Session ended before output began.")
            return .destinationCancelled
        case .fileFailure(let code, let message):
            return await cancelKnownFailure(prepared, effectError: message, effectCode: code)
        case .failed(let effectError):
            return await cancelKnownFailure(prepared, effectError: effectError)
        }
    }

    private func finalizeKnownSuccess(
        _ prepared: WorktreeAnnotationSQLiteRepository.PreparedOutput,
        destinationPath: String?
    ) async -> WorktreeAnnotationOutputExecutionResult {
        do {
            let finalized = try await store.finalizeOutputAttempt(
                attemptID: prepared.attempt.id,
                eventKind: prepared.attempt.outputKind == .clipboardMarkdown ? .copied : .exported,
                destinationPath: destinationPath,
                now: now()
            )
            return .succeeded(finalized)
        } catch {
            let finalizationError = String(describing: error)
            let recordedOutput: WorktreeAnnotationSQLiteRepository.PreparedOutput
            do {
                recordedOutput = try await store.markOutputAttemptFinalizationFailed(
                    attemptID: prepared.attempt.id,
                    cleanupError: finalizationError,
                    destinationPath: destinationPath,
                    now: now()
                )
            } catch {
                recordedOutput = prepared
            }
            return .partialSuccess(
                output: recordedOutput,
                finalizationError: finalizationError
            )
        }
    }

    private func cancelKnownFailure(
        _ prepared: WorktreeAnnotationSQLiteRepository.PreparedOutput,
        effectError: String,
        effectCode: WorktreeAnnotationOutputFileFailureCode? = nil
    ) async -> WorktreeAnnotationOutputExecutionResult {
        do {
            let cancelled = try await store.cancelOutputAttempt(
                attemptID: prepared.attempt.id,
                effectError: effectError,
                now: now()
            )
            return .effectFailed(effectError: effectError, effectCode: effectCode, output: cancelled)
        } catch {
            cancellationProofByAttemptID[prepared.attempt.id] = .init(effectError: effectError)
            return .effectAndCleanupFailed(
                output: prepared,
                effectError: effectError,
                effectCode: effectCode,
                cleanupError: String(describing: error)
            )
        }
    }

    @concurrent nonisolated private static func materialize(
        request: WorktreeAnnotationOutputRequest,
        attemptID: WorktreeAnnotationOutputAttemptID,
        createdAt: Date
    ) async throws -> MaterializedOutput {
        let snapshot = try WorktreeAnnotationBatchProjector.makeSnapshot(
            .init(
                batchID: attemptID,
                createdAt: createdAt,
                sessionDetail: request.sessionDetail,
                selectedMessages: request.selectedMessages,
                placementsByThreadID: request.placementsByThreadID,
                sessionLabel: request.sessionLabel,
                worktreeLabel: request.worktreeLabel,
                comparisonLabel: request.comparisonLabel
            )
        )
        switch request.outputKind {
        case .clipboardMarkdown:
            let presentation = WorktreeAnnotationMarkdownPresentationContext(
                worktreeLabel: request.worktreeLabel,
                comparisonLabel: request.comparisonLabel
            )
            return MaterializedOutput(
                snapshot: snapshot,
                exactBytes: WorktreeAnnotationBatchProjector.markdownData(
                    for: snapshot,
                    presentation: presentation
                ),
                contentType: "text/markdown; charset=utf-8",
                markdownPresentation: presentation
            )
        case .jsonFile:
            return try MaterializedOutput(
                snapshot: snapshot,
                exactBytes: WorktreeAnnotationBatchProjector.jsonData(for: snapshot),
                contentType: "application/json; charset=utf-8",
                markdownPresentation: nil
            )
        }
    }

    private enum DestinationResolution {
        case resolved(String?)
        case cancelled
        case failed(String)
    }

    private func resolveDestination(
        outputKind: WorktreeAnnotationOutputKind,
        destination: BridgeProductWorktreeAnnotationOperation.OutputDestination?,
        productAdmission: BridgeProductAdmissionContext
    ) async -> DestinationResolution {
        switch outputKind {
        case .clipboardMarkdown:
            return .resolved(nil)
        case .jsonFile:
            let outcome: WorktreeAnnotationOutputDestinationOutcome =
                switch destination {
                case .remembered: .selected(path: await effect.rememberedJSONFolder())
                case .choose: await effect.chooseJSONDestination(productAdmission: productAdmission)
                case nil: .failed("JSON export has no destination selection.")
                }
            switch outcome {
            case .selected(let path):
                guard !path.isEmpty else {
                    return .failed("The selected export destination was empty.")
                }
                return .resolved(path)
            case .cancelled:
                return .cancelled
            case .failed(let error):
                return .failed(error)
            }
        }
    }
}
