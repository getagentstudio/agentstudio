import AgentStudioInfrastructure
import Foundation
import Synchronization

typealias TerminalMainActorDrainOperation = @MainActor @Sendable () async -> Void
typealias TerminalTitleDeadlineScheduler =
    @Sendable (
        UInt64,
        @escaping @Sendable () -> Void
    ) -> Void

/// Owns one scheduler claim per independent local-action lane.
final class TerminalLocalActionDrainScheduler: Sendable {
    private enum ClaimPhase: Sendable {
        case titleDeadline
        case mainActorAdmission
    }

    private struct ClaimKey: Hashable, Sendable {
        let surfaceID: UUID
        let lane: TerminalLocalActionLane
    }

    private struct DrainClaim: Sendable {
        let token: UInt64
        var phase: ClaimPhase
        var followUpRequest: TerminalLocalDrainRequest?
        let operation: TerminalMainActorDrainOperation
    }

    private struct State: Sendable {
        var nextToken: UInt64 = 0
        var claims: [ClaimKey: DrainClaim] = [:]
    }

    private let state = Mutex(State())
    private let schedulingQueue = DispatchQueue(
        label: "com.agentstudio.terminal-local-action-drain", qos: .userInteractive)
    private let drain:
        @MainActor @Sendable (UUID, TerminalLocalActionLane, TerminalLocalActionAccumulator) async -> Void
    private let scheduleTitleDeadline: TerminalTitleDeadlineScheduler
    private let enqueueMainActorDrain: @Sendable (@escaping TerminalMainActorDrainOperation) -> Void

    init(
        drain:
            @escaping @MainActor @Sendable (UUID, TerminalLocalActionLane, TerminalLocalActionAccumulator) async -> Void,
        scheduleTitleDeadline: TerminalTitleDeadlineScheduler? = nil,
        enqueueMainActorDrain: (@Sendable (@escaping TerminalMainActorDrainOperation) -> Void)? = nil
    ) {
        self.drain = drain
        self.scheduleTitleDeadline =
            scheduleTitleDeadline ?? { [schedulingQueue] deadline, operation in
                schedulingQueue.asyncAfter(
                    deadline: DispatchTime(
                        uptimeNanoseconds: Self.titleAdmissionDeadline(
                            forPublicationDeadline: deadline
                        )
                    ),
                    execute: operation
                )
            }
        self.enqueueMainActorDrain =
            enqueueMainActorDrain ?? { operation in
                Task { @MainActor in await operation() }
            }
    }

    func schedule(
        _ surfaceID: UUID, _ request: TerminalLocalDrainRequest, _ accumulator: TerminalLocalActionAccumulator
    ) {
        let operation: TerminalMainActorDrainOperation = { [drain, weak accumulator] in
            guard let accumulator else { return }
            await drain(surfaceID, request.lane, accumulator)
        }
        let key = ClaimKey(surfaceID: surfaceID, lane: request.lane)
        switch request.lane {
        case .immediate: scheduleImmediate(key: key, operation: operation)
        case .title: scheduleTitle(key: key, request: request, operation: operation)
        }
    }

    func scheduleFollowUp(
        _ surfaceID: UUID, _ request: TerminalLocalDrainRequest, _ accumulator: TerminalLocalActionAccumulator
    ) {
        let key = ClaimKey(surfaceID: surfaceID, lane: request.lane)
        let scheduleNormally = state.withLock { storage -> Bool in
            guard var claim = storage.claims[key] else { return true }
            claim.followUpRequest = request
            storage.claims[key] = claim
            return false
        }
        if scheduleNormally { schedule(surfaceID, request, accumulator) }
    }

    func cancelAll() {
        state.withLock { $0.claims.removeAll() }
    }

    func cancel(for surfaceID: UUID) {
        state.withLock { storage in
            for key in storage.claims.keys.filter({ $0.surfaceID == surfaceID }) {
                storage.claims.removeValue(forKey: key)
            }
        }
    }

    func cancelTitle(for surfaceID: UUID) {
        let key = ClaimKey(surfaceID: surfaceID, lane: .title)
        state.withLock { storage in
            _ = storage.claims.removeValue(forKey: key)
        }
    }

    var pendingDrainClaimCount: Int { state.withLock { $0.claims.count } }

    static func titleAdmissionDeadline(forPublicationDeadline deadline: UInt64) -> UInt64 {
        let admissionSlack = AppPolicies.TerminalLocalAction.titleMainActorAdmissionSlackNanoseconds
        return deadline > admissionSlack ? deadline - admissionSlack : 0
    }

    private func scheduleTitle(
        key: ClaimKey, request: TerminalLocalDrainRequest, operation: @escaping TerminalMainActorDrainOperation
    ) {
        guard let deadline = request.absoluteDeadlineNanoseconds else {
            preconditionFailure("Title requests require an absolute deadline")
        }
        let token = state.withLock { storage -> UInt64? in
            guard storage.claims[key] == nil else { return nil }
            storage.nextToken &+= 1
            let token = storage.nextToken
            storage.claims[key] = DrainClaim(
                token: token, phase: .titleDeadline, followUpRequest: nil, operation: operation)
            return token
        }
        guard let token else { return }
        scheduleTitleDeadline(deadline) { [weak self] in
            self?.claimTitleDeadline(key: key, token: token)
        }
    }

    private func scheduleImmediate(key: ClaimKey, operation: @escaping TerminalMainActorDrainOperation) {
        let token = state.withLock { storage -> UInt64? in
            guard storage.claims[key] == nil else { return nil }
            storage.nextToken &+= 1
            let token = storage.nextToken
            storage.claims[key] = DrainClaim(
                token: token, phase: .mainActorAdmission, followUpRequest: nil, operation: operation)
            return token
        }
        if let token { enqueueClaimedDrain(key: key, token: token) }
    }

    private func claimTitleDeadline(key: ClaimKey, token: UInt64) {
        let shouldEnqueue = state.withLock { storage -> Bool in
            guard
                var claim = storage.claims[key],
                claim.token == token,
                case .titleDeadline = claim.phase
            else { return false }
            claim.phase = .mainActorAdmission
            storage.claims[key] = claim
            return true
        }
        if shouldEnqueue { enqueueClaimedDrain(key: key, token: token) }
    }

    private func enqueueClaimedDrain(key: ClaimKey, token: UInt64) {
        enqueueMainActorDrain { [weak self] in
            guard let self, let operation = self.currentOperation(key: key, token: token) else { return }
            await operation()
            self.completeClaim(key: key, token: token)
        }
    }

    private func currentOperation(key: ClaimKey, token: UInt64) -> TerminalMainActorDrainOperation? {
        state.withLock { storage in
            guard let claim = storage.claims[key], claim.token == token else { return nil }
            return claim.operation
        }
    }

    private func completeClaim(key: ClaimKey, token: UInt64) {
        let followUp = state.withLock { storage -> (TerminalLocalDrainRequest, TerminalMainActorDrainOperation)? in
            guard let claim = storage.claims[key], claim.token == token else { return nil }
            storage.claims.removeValue(forKey: key)
            guard let request = claim.followUpRequest else { return nil }
            return (request, claim.operation)
        }
        if let (request, operation) = followUp {
            switch request.lane {
            case .immediate: scheduleImmediate(key: key, operation: operation)
            case .title: scheduleTitle(key: key, request: request, operation: operation)
            }
        }
    }
}
