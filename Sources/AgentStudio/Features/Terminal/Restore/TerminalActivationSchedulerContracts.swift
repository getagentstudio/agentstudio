import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

package struct TerminalActivationCohort: Equatable, Sendable {
    package let generation: WorkspaceContentMountGeneration
    package let input: TerminalActivationInput

    package init(
        generation: WorkspaceContentMountGeneration,
        input: TerminalActivationInput
    ) {
        self.generation = generation
        self.input = input
    }
}

package struct TerminalActivationAdmission: Equatable, Sendable {
    package let generation: WorkspaceContentMountGeneration
    package let descriptor: TerminalActivationDescriptor
    package let attempt: Int
    /// SR1: this pane's restore decision, computed once by `mount()` before
    /// the terminal lane activates (Program Design item 1) and installed on
    /// the admission port ahead of any claim. `nil` for a pane the launch
    /// cohort never covered — the mount effect then falls back to today's
    /// plain attach (`TerminalRestoreRuntime.startupCommand(for:kind:)`).
    package let restoreKind: TerminalRestoreKind?

    package init(
        generation: WorkspaceContentMountGeneration,
        descriptor: TerminalActivationDescriptor,
        attempt: Int,
        restoreKind: TerminalRestoreKind? = nil
    ) {
        self.generation = generation
        self.descriptor = descriptor
        self.attempt = attempt
        self.restoreKind = restoreKind
    }
}

package enum TerminalActivationFailure: Equatable, Sendable {
    case attachmentRejected(code: String)
    case surfaceCreationFailed(code: String)
    case surfaceAttachmentFailed(code: String)
}

package enum TerminalActivationRetryDirective: Equatable, Sendable {
    case retry
    case doNotRetry
}

package enum TerminalActivationAttemptResult: Equatable, Sendable {
    case ready(surfaceID: UUID)
    case failed(
        failure: TerminalActivationFailure,
        retry: TerminalActivationRetryDirective
    )
}

package enum TerminalActivationRetry: Equatable, Sendable {
    case notRequested(attemptCount: Int)
    case exhausted(attemptCount: Int)
}

package enum TerminalActivationMemberState: Equatable, Sendable {
    /// Held before this pane's geometry eligibility is installed (SPEC R5,
    /// the R1 deferral half). Not a candidate for admission and not
    /// promotable — distinct from `queued`, which has already entered the
    /// rank-ordered candidate pool.
    case waitingForGeometry
    case queued(priority: TerminalActivationVisibilityPriority)
    case attaching
    case ready(surfaceID: UUID)
    case failedTerminal(
        failure: TerminalActivationFailure,
        retry: TerminalActivationRetry
    )
    case cancelledReplaced(replacement: WorkspaceContentMountGeneration)

    var isTerminal: Bool {
        switch self {
        case .waitingForGeometry, .queued, .attaching:
            return false
        case .ready, .failedTerminal, .cancelledReplaced:
            return true
        }
    }
}

package enum TerminalActivationTerminalOutcome: Equatable, Sendable {
    /// A terminal outcome for the settlement that produced it, but not a
    /// terminal state for the pane's later eligibility: `acceptLaterGeometry`
    /// can still requeue this pane in the same generation and scheduler.
    case waitingForGeometry
    case ready(surfaceID: UUID)
    case failedTerminal(
        failure: TerminalActivationFailure,
        retry: TerminalActivationRetry
    )
    case cancelledReplaced(replacement: WorkspaceContentMountGeneration)
}

package struct TerminalActivationSettlement: Equatable, Sendable {
    package let generation: WorkspaceContentMountGeneration
    package let outcomesByPaneID: [PaneId: TerminalActivationTerminalOutcome]

    package init(
        generation: WorkspaceContentMountGeneration,
        outcomesByPaneID: [PaneId: TerminalActivationTerminalOutcome]
    ) {
        self.generation = generation
        self.outcomesByPaneID = outcomesByPaneID
    }
}

struct TerminalActivationSchedulerDiagnostics: Equatable, Sendable {
    let currentSimultaneousAdmissions: Int
    let maximumSimultaneousAdmissions: Int
    let workerCount: Int
    let yieldCount: Int
}

package protocol TerminalActivationReleaseSignal: Sendable {
    func waitUntilReleased() async -> StartupDeferralOutcome
}

package actor TerminalActivationReleaseGate: TerminalActivationReleaseSignal {
    private struct Waiter {
        let continuation: CheckedContinuation<StartupDeferralOutcome, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var isReleased: Bool
    private let deferralDelay: AsyncDelay
    private var waiters: [UUID: Waiter] = [:]

    package init(
        isReleased: Bool,
        deferralDelay: AsyncDelay = .taskSleep
    ) {
        self.isReleased = isReleased
        self.deferralDelay = deferralDelay
    }

    package func hold() {
        precondition(waiters.isEmpty, "terminal activation gate cannot close while activation is waiting")
        isReleased = false
    }

    package func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiterIDs = Array(waiters.keys)
        for waiterID in waiterIDs {
            resolveWaiter(waiterID, outcome: .completed)
        }
    }

    package func waitUntilReleased() async -> StartupDeferralOutcome {
        guard !isReleased else { return .completed }
        let waiterID = UUIDv7.generate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let delay = deferralDelay
                let timeoutTask = Task { [weak self] in
                    do {
                        try await delay.wait(AppPolicies.StartupDeferral.maximumWait)
                    } catch {
                        return
                    }
                    await self?.resolveWaiter(waiterID, outcome: .fallbackTimeout)
                }
                waiters[waiterID] = Waiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolveWaiter(waiterID, outcome: .cancelled)
            }
        }
    }

    private func resolveWaiter(_ waiterID: UUID, outcome: StartupDeferralOutcome) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: outcome)
    }
}

package enum TerminalActivationPromotionResult: Equatable, Sendable {
    case promoted(
        from: TerminalActivationVisibilityPriority,
        to: TerminalActivationVisibilityPriority
    )
    case unchanged(priority: TerminalActivationVisibilityPriority)
    case paneNotFound
    case memberNotQueued(state: TerminalActivationMemberState)
}
