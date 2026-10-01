import AgentStudioInfrastructure
import Foundation

struct BridgeFileSurfaceInputBasis: Equatable, Sendable {
    struct Root: Equatable, Sendable {
        let rootPathToken: String
    }

    struct Membership: Equatable, Sendable {
        let repoId: String
        let worktreeId: String
        let cwdScope: String?
        let includeStatuses: Bool
    }

    let root: Root
    let filter: BridgeProductJSONValue
    let canonicalPathScope: [String]
    let membership: Membership

    init(
        root: Root,
        filter: BridgeProductJSONValue,
        canonicalPathScope: [String],
        membership: Membership
    ) {
        self.root = root
        self.filter = filter
        self.canonicalPathScope = canonicalPathScope.sorted()
        self.membership = membership
    }

    static func admitted(
        source: BridgeProductFileSourceSpec,
        scope: BridgeProductJSONValue?
    ) -> Self {
        let scopeMembers: [String: BridgeProductJSONValue]
        if case .object(let members)? = scope {
            scopeMembers = members
        } else {
            scopeMembers = [:]
        }
        let filter = scopeMembers["changeFilter"] ?? .object(["kind": .string("none")])
        let canonicalPathScope: [String]
        if case .array(let values)? = scopeMembers["pathScope"] {
            canonicalPathScope = values.compactMap { value in
                guard case .string(let path) = value else { return nil }
                return path
            }
        } else {
            canonicalPathScope = []
        }
        return Self(
            root: .init(rootPathToken: source.rootPathToken),
            filter: filter,
            canonicalPathScope: canonicalPathScope,
            membership: .init(
                repoId: source.repoId,
                worktreeId: source.worktreeId,
                cwdScope: source.cwdScope,
                includeStatuses: source.includeStatuses
            )
        )
    }
}

actor BridgeFileSurfaceReconciler {
    struct Attempt: Equatable, Sendable {
        let inputGeneration: UInt64
        let nonce: UUID
    }

    enum FailureDisposition: Equatable, Sendable {
        case retryable
        case permanent
    }

    enum FailurePhase: String, Equatable, Sendable {
        case build
        case delivery
    }

    enum FailureCause: String, Equatable, Sendable {
        case missingRoot
        case unreadableRoot
        case accessRefused
        case providerCancellation
        case constructionInvalidated
        case repeatedSupersession
        case interruptedRepeatedly
        case progressExpired
        case providerFailure
        case unrecognizedProviderFailure
    }

    struct Failure: Equatable, Sendable {
        let disposition: FailureDisposition
        let phase: FailurePhase
        let cause: FailureCause

        var refreshFailure: BridgePaneProductFileRefreshFailure {
            switch disposition {
            case .retryable:
                .init(failureKind: .fileSourceUnavailable)
            case .permanent:
                .init(failureKind: .producerRejected)
            }
        }
    }

    enum BuilderOutcome: Equatable, Sendable {
        case built
        case superseded(newerInputBasis: BridgeFileSurfaceInputBasis)
        case failed(Failure)
    }

    enum Action: Equatable, Sendable {
        case start(Attempt)
        case restart(retiring: Attempt, starting: Attempt)
        case completed(Attempt)
        case rest
        case failed(Failure)
    }

    private(set) var currentInputGeneration: UInt64?
    private(set) var currentInputBasis: BridgeFileSurfaceInputBasis?
    private(set) var activeAttempt: Attempt?
    private(set) var retiringAttempt: Attempt?
    private(set) var currentFailure: Failure?
    private let maximumUnchangedInputSupersessions: Int
    private let interruptionRestartLimit: Int
    private var unchangedInputSupersessionCount = 0
    private var consecutiveInterruptionCount = 0

    init(
        maximumUnchangedInputSupersessions: Int = AppPolicies.Bridge
            .fileSurfaceMaximumUnchangedInputSupersessions,
        interruptionRestartLimit: Int = AppPolicies.Bridge.fileSurfaceInterruptionRestartLimit
    ) {
        precondition(maximumUnchangedInputSupersessions > 0)
        precondition(interruptionRestartLimit > 0)
        self.maximumUnchangedInputSupersessions = maximumUnchangedInputSupersessions
        self.interruptionRestartLimit = interruptionRestartLimit
    }

    func beginAttempt(inputBasis: BridgeFileSurfaceInputBasis) -> Action {
        guard activeAttempt == nil else { return .rest }
        guard currentFailure == nil else { return .rest }
        guard currentInputBasis == inputBasis else {
            return inputsChanged(to: inputBasis)
        }
        guard let currentInputGeneration else { return inputsChanged(to: inputBasis) }
        return startAttempt(inputGeneration: currentInputGeneration)
    }

    func inputsChanged(to inputBasis: BridgeFileSurfaceInputBasis) -> Action {
        guard currentInputBasis != inputBasis else { return .rest }
        currentInputBasis = inputBasis
        currentInputGeneration = (currentInputGeneration ?? 0) &+ 1
        unchangedInputSupersessionCount = 0
        consecutiveInterruptionCount = 0
        currentFailure = nil
        guard let activeAttempt else {
            return startAttempt(inputGeneration: currentInputGeneration ?? 1)
        }
        retiringAttempt = activeAttempt
        let successor = makeAttempt(inputGeneration: currentInputGeneration ?? 1)
        self.activeAttempt = successor
        return .restart(retiring: activeAttempt, starting: successor)
    }

    func builderFinished(
        _ attempt: Attempt,
        outcome: BuilderOutcome
    ) -> Action {
        guard activeAttempt == attempt,
            let currentInputBasis,
            let currentInputGeneration
        else { return .rest }

        switch outcome {
        case .built:
            activeAttempt = nil
            consecutiveInterruptionCount = 0
            currentFailure = nil
            return .completed(attempt)
        case .superseded(let newerInputBasis):
            if newerInputBasis != currentInputBasis {
                return inputsChanged(to: newerInputBasis)
            }

            activeAttempt = nil
            unchangedInputSupersessionCount += 1
            guard unchangedInputSupersessionCount <= maximumUnchangedInputSupersessions else {
                let failure = Failure(
                    disposition: .retryable,
                    phase: .build,
                    cause: .repeatedSupersession
                )
                currentFailure = failure
                return .failed(failure)
            }
            return startAttempt(inputGeneration: currentInputGeneration)
        case .failed(let failure):
            activeAttempt = nil
            currentFailure = failure
            return .failed(failure)
        }
    }

    func builderFailed(
        _ attempt: Attempt,
        error: any Error,
        phase: FailurePhase,
        newerInputBasis: BridgeFileSurfaceInputBasis? = nil
    ) -> Action {
        guard activeAttempt == attempt else { return .rest }
        if let newerInputBasis {
            return builderFinished(
                attempt,
                outcome: .superseded(newerInputBasis: newerInputBasis)
            )
        }
        return builderFinished(
            attempt,
            outcome: .failed(Self.failure(for: error, phase: phase))
        )
    }

    func builderCancelled(
        _ attempt: Attempt,
        phase: FailurePhase = .delivery,
        isAutomaticRestartEligible: Bool = false
    ) -> Action {
        guard activeAttempt == attempt else { return .rest }
        activeAttempt = nil
        retiringAttempt = attempt
        guard isAutomaticRestartEligible else { return .rest }

        consecutiveInterruptionCount += 1
        guard consecutiveInterruptionCount > interruptionRestartLimit else { return .rest }
        let failure = Failure(
            disposition: .retryable,
            phase: phase,
            cause: .interruptedRepeatedly
        )
        currentFailure = failure
        return .failed(failure)
    }

    func retry() -> Action {
        guard activeAttempt == nil,
            currentFailure?.disposition == .retryable,
            let currentInputGeneration
        else { return .rest }
        currentFailure = nil
        unchangedInputSupersessionCount = 0
        consecutiveInterruptionCount = 0
        return startAttempt(inputGeneration: currentInputGeneration)
    }

    func retirementCompleted(_ attempt: Attempt) {
        guard retiringAttempt == attempt else { return }
        retiringAttempt = nil
    }

    private func startAttempt(inputGeneration: UInt64) -> Action {
        let attempt = makeAttempt(inputGeneration: inputGeneration)
        activeAttempt = attempt
        return .start(attempt)
    }

    private func makeAttempt(inputGeneration: UInt64) -> Attempt {
        Attempt(inputGeneration: inputGeneration, nonce: UUIDv7.generate())
    }

    static func failure(
        for error: any Error,
        phase: FailurePhase
    ) -> Failure {
        if let rootAccessError = error as? BridgeWorktreeFileRootAccessError {
            switch rootAccessError {
            case .missingRoot:
                return Failure(disposition: .retryable, phase: phase, cause: .missingRoot)
            case .unreadable:
                return Failure(disposition: .retryable, phase: phase, cause: .unreadableRoot)
            case .refused:
                return Failure(disposition: .permanent, phase: phase, cause: .accessRefused)
            }
        }
        if error is CancellationError {
            return Failure(disposition: .retryable, phase: phase, cause: .providerCancellation)
        }
        if (error as? BridgeWorktreeProductConstructionError) == .invalidated {
            return Failure(disposition: .retryable, phase: phase, cause: .constructionInvalidated)
        }
        if let coordinatorError = error as? BridgePaneProductMetadataCoordinatorError {
            switch coordinatorError {
            case .foregroundWorkInvalidated:
                return Failure(disposition: .retryable, phase: phase, cause: .providerCancellation)
            case .producerQueueReset:
                return Failure(disposition: .retryable, phase: phase, cause: .providerFailure)
            case .producerRejected:
                return Failure(disposition: .permanent, phase: phase, cause: .providerFailure)
            }
        }
        if error is BridgePaneProductFileMetadataSourceError {
            return Failure(disposition: .retryable, phase: phase, cause: .providerFailure)
        }
        return Failure(
            disposition: .retryable,
            phase: phase,
            cause: .unrecognizedProviderFailure
        )
    }
}
