import AgentStudioGit
import CoreServices
import Foundation

package enum GitCleanContinuityFailureReason: String, Sendable, Equatable {
    case unsupportedObservation
    case registrationMissing
    case registrationReplaced
    case identityChanged
    case mutationObserved
    case eventStreamUncertain
    case streamStartFailed
    case shutdown
}

package struct GitCleanContinuityBarrier: Sendable, Equatable {
    package let registrationId: UUID
    package let observationIdentity: AgentStudioGit.GitStatusObservationIdentity
    package let registrationGeneration: UInt64
    package let mutationEpoch: UInt64
    package let uncertaintyEpoch: UInt64
    package let observedAncestorAmbiguityEpoch: UInt64

    package init(
        registrationId: UUID,
        observationIdentity: AgentStudioGit.GitStatusObservationIdentity,
        registrationGeneration: UInt64,
        mutationEpoch: UInt64,
        uncertaintyEpoch: UInt64,
        observedAncestorAmbiguityEpoch: UInt64 = 0
    ) {
        self.registrationId = registrationId
        self.observationIdentity = observationIdentity
        self.registrationGeneration = registrationGeneration
        self.mutationEpoch = mutationEpoch
        self.uncertaintyEpoch = uncertaintyEpoch
        self.observedAncestorAmbiguityEpoch = observedAncestorAmbiguityEpoch
    }
}

package struct GitCleanContinuityAuthority: Sendable, Equatable {
    package let registrationId: UUID
    package let observationIdentity: AgentStudioGit.GitStatusObservationIdentity
    package let registrationGeneration: UInt64
    package let mutationEpoch: UInt64
    package let uncertaintyEpoch: UInt64
    package let resolvedAncestorAmbiguityEpoch: UInt64

    package init(
        registrationId: UUID,
        observationIdentity: AgentStudioGit.GitStatusObservationIdentity,
        registrationGeneration: UInt64,
        mutationEpoch: UInt64,
        uncertaintyEpoch: UInt64,
        resolvedAncestorAmbiguityEpoch: UInt64 = 0
    ) {
        self.registrationId = registrationId
        self.observationIdentity = observationIdentity
        self.registrationGeneration = registrationGeneration
        self.mutationEpoch = mutationEpoch
        self.uncertaintyEpoch = uncertaintyEpoch
        self.resolvedAncestorAmbiguityEpoch = resolvedAncestorAmbiguityEpoch
    }
}

package enum GitCleanContinuityAuthorityValidation: Sendable, Equatable {
    case authoritative(GitCleanContinuityAuthority)
    case requiresExact(GitCleanContinuityFailureReason)
}

/// Lock-protected authority ledger updated directly from the raw FSEvents callback.
///
/// Ordinary filesystem delivery is intentionally lossy. This ledger therefore
/// records mutation and uncertainty before a batch enters that delivery path.
package final class GitCleanContinuityLedger: @unchecked Sendable {
    private struct RegistrationState {
        let identity: AgentStudioGit.GitStatusObservationIdentity
        let generation: UInt64
        var mutationEpoch: UInt64
        var uncertaintyEpoch: UInt64
        var observedAncestorAmbiguityEpoch: UInt64
        var resolvedAncestorAmbiguityEpoch: UInt64
        var latestEventId: FSEventStreamEventId?
    }

    private static let uncertaintyFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
    )

    private let lock = NSLock()
    private var nextRegistrationGeneration: UInt64 = 0
    private var registrationById: [UUID: RegistrationState] = [:]
    private var hasShutdown = false

    package init() {}

    package func register(
        registrationId: UUID,
        identity: AgentStudioGit.GitStatusObservationIdentity,
        preserveAncestorAmbiguity: Bool = false
    ) {
        lock.withLock {
            guard !hasShutdown else { return }
            let previousRegistration = registrationById[registrationId]
            let preservesPreviousAmbiguity =
                preserveAncestorAmbiguity
                && previousRegistration?.identity == identity
            nextRegistrationGeneration &+= 1
            registrationById[registrationId] = RegistrationState(
                identity: identity,
                generation: nextRegistrationGeneration,
                mutationEpoch: 0,
                uncertaintyEpoch: 0,
                observedAncestorAmbiguityEpoch: preservesPreviousAmbiguity
                    ? previousRegistration?.observedAncestorAmbiguityEpoch ?? 0
                    : 0,
                resolvedAncestorAmbiguityEpoch: preservesPreviousAmbiguity
                    ? previousRegistration?.resolvedAncestorAmbiguityEpoch ?? 0
                    : 0,
                latestEventId: nil
            )
        }
    }

    package func unregister(registrationId: UUID) {
        _ = lock.withLock {
            registrationById.removeValue(forKey: registrationId)
        }
    }

    package func beginBarrier(
        registrationId: UUID,
        identity: AgentStudioGit.GitStatusObservationIdentity
    ) -> GitCleanContinuityBarrier? {
        lock.withLock {
            guard !hasShutdown,
                let registration = registrationById[registrationId],
                registration.identity == identity
            else {
                return nil
            }
            return GitCleanContinuityBarrier(
                registrationId: registrationId,
                observationIdentity: identity,
                registrationGeneration: registration.generation,
                mutationEpoch: registration.mutationEpoch,
                uncertaintyEpoch: registration.uncertaintyEpoch,
                observedAncestorAmbiguityEpoch: registration.observedAncestorAmbiguityEpoch
            )
        }
    }

    package func barrierIsCurrent(
        _ barrier: GitCleanContinuityBarrier
    ) -> GitCleanContinuityFailureReason? {
        lock.withLock {
            barrierFailureReason(barrier)
        }
    }

    package func commitBarrier(
        _ barrier: GitCleanContinuityBarrier
    ) -> GitCleanContinuityAuthorityValidation {
        lock.withLock {
            if let failureReason = barrierFailureReason(barrier) {
                return .requiresExact(failureReason)
            }
            guard var registration = registrationById[barrier.registrationId] else {
                return .requiresExact(.registrationMissing)
            }
            registration.resolvedAncestorAmbiguityEpoch =
                barrier.observedAncestorAmbiguityEpoch
            registrationById[barrier.registrationId] = registration
            return .authoritative(
                GitCleanContinuityAuthority(
                    registrationId: barrier.registrationId,
                    observationIdentity: barrier.observationIdentity,
                    registrationGeneration: barrier.registrationGeneration,
                    mutationEpoch: barrier.mutationEpoch,
                    uncertaintyEpoch: barrier.uncertaintyEpoch,
                    resolvedAncestorAmbiguityEpoch: barrier.observedAncestorAmbiguityEpoch
                )
            )
        }
    }

    package func renew(
        _ authority: GitCleanContinuityAuthority
    ) -> GitCleanContinuityAuthorityValidation {
        lock.withLock {
            guard !hasShutdown else { return .requiresExact(.shutdown) }
            guard let registration = registrationById[authority.registrationId] else {
                return .requiresExact(.registrationMissing)
            }
            guard registration.identity == authority.observationIdentity else {
                return .requiresExact(.identityChanged)
            }
            guard registration.generation == authority.registrationGeneration else {
                return .requiresExact(.registrationReplaced)
            }
            guard registration.mutationEpoch == authority.mutationEpoch else {
                return .requiresExact(.mutationObserved)
            }
            guard registration.uncertaintyEpoch == authority.uncertaintyEpoch else {
                return .requiresExact(.eventStreamUncertain)
            }
            guard
                registration.observedAncestorAmbiguityEpoch
                    == registration.resolvedAncestorAmbiguityEpoch,
                authority.resolvedAncestorAmbiguityEpoch
                    <= registration.resolvedAncestorAmbiguityEpoch
            else {
                return .requiresExact(.eventStreamUncertain)
            }
            return .authoritative(
                GitCleanContinuityAuthority(
                    registrationId: authority.registrationId,
                    observationIdentity: authority.observationIdentity,
                    registrationGeneration: authority.registrationGeneration,
                    mutationEpoch: authority.mutationEpoch,
                    uncertaintyEpoch: authority.uncertaintyEpoch,
                    resolvedAncestorAmbiguityEpoch: registration.resolvedAncestorAmbiguityEpoch
                )
            )
        }
    }

    package func authorityIsCurrentForAncestorRecheck(
        _ authority: GitCleanContinuityAuthority
    ) -> Bool {
        lock.withLock {
            authorityFailureReasonIgnoringAncestorAmbiguity(authority) == nil
        }
    }

    package func currentObservedAncestorAmbiguityEpoch(
        expectedAuthority authority: GitCleanContinuityAuthority
    ) -> UInt64? {
        lock.withLock {
            guard authorityFailureReasonIgnoringAncestorAmbiguity(authority) == nil else {
                return nil
            }
            return registrationById[authority.registrationId]?.observedAncestorAmbiguityEpoch
        }
    }

    package func resolveAncestorAmbiguity(
        expectedAuthority authority: GitCleanContinuityAuthority,
        expectedObservedEpoch: UInt64
    ) -> GitCleanContinuityAuthorityValidation {
        lock.withLock {
            if let failureReason = authorityFailureReasonIgnoringAncestorAmbiguity(authority) {
                return .requiresExact(failureReason)
            }
            guard var registration = registrationById[authority.registrationId] else {
                return .requiresExact(.registrationMissing)
            }
            guard registration.observedAncestorAmbiguityEpoch == expectedObservedEpoch else {
                return .requiresExact(.eventStreamUncertain)
            }
            registration.resolvedAncestorAmbiguityEpoch = expectedObservedEpoch
            registrationById[authority.registrationId] = registration
            return .authoritative(
                GitCleanContinuityAuthority(
                    registrationId: authority.registrationId,
                    observationIdentity: authority.observationIdentity,
                    registrationGeneration: authority.registrationGeneration,
                    mutationEpoch: authority.mutationEpoch,
                    uncertaintyEpoch: authority.uncertaintyEpoch,
                    resolvedAncestorAmbiguityEpoch: expectedObservedEpoch
                )
            )
        }
    }

    @discardableResult
    package func recordAncestorAmbiguity(registrationId: UUID) -> UInt64? {
        lock.withLock {
            guard !hasShutdown, var registration = registrationById[registrationId] else {
                return nil
            }
            registration.observedAncestorAmbiguityEpoch &+= 1
            registrationById[registrationId] = registration
            return registration.observedAncestorAmbiguityEpoch
        }
    }

    package func recordMutation(
        registrationId: UUID,
        eventId: FSEventStreamEventId
    ) {
        recordRawEvent(
            registrationId: registrationId,
            eventId: eventId,
            flags: 0,
            hasRelevantMutation: true
        )
    }

    package func recordRawEvent(
        registrationId: UUID,
        eventId: FSEventStreamEventId,
        flags: FSEventStreamEventFlags,
        hasRelevantMutation: Bool
    ) {
        lock.withLock {
            guard !hasShutdown, var registration = registrationById[registrationId] else { return }
            Self.applyRawEvent(
                eventId: eventId,
                flags: flags,
                hasRelevantMutation: hasRelevantMutation,
                to: &registration
            )
            registrationById[registrationId] = registration
        }
    }

    package func recordRawEvents(
        registrationId: UUID,
        events: [DarwinFSEventClassifiedRawEvent]
    ) {
        guard !events.isEmpty else { return }
        lock.withLock {
            guard !hasShutdown, var registration = registrationById[registrationId] else { return }
            for event in events {
                Self.applyRawEvent(
                    eventId: event.eventId,
                    flags: event.flags,
                    hasRelevantMutation: event.hasRelevantMutation,
                    to: &registration
                )
            }
            registrationById[registrationId] = registration
        }
    }

    package func markUncertain(registrationId: UUID) {
        lock.withLock {
            guard !hasShutdown, var registration = registrationById[registrationId] else { return }
            registration.uncertaintyEpoch &+= 1
            registrationById[registrationId] = registration
        }
    }

    package func shutdown() {
        lock.withLock {
            hasShutdown = true
            registrationById.removeAll(keepingCapacity: false)
        }
    }

    private func barrierFailureReason(
        _ barrier: GitCleanContinuityBarrier
    ) -> GitCleanContinuityFailureReason? {
        guard !hasShutdown else { return .shutdown }
        guard let registration = registrationById[barrier.registrationId] else {
            return .registrationMissing
        }
        guard registration.identity == barrier.observationIdentity else {
            return .identityChanged
        }
        guard registration.generation == barrier.registrationGeneration else {
            return .registrationReplaced
        }
        guard registration.mutationEpoch == barrier.mutationEpoch else {
            return .mutationObserved
        }
        guard registration.uncertaintyEpoch == barrier.uncertaintyEpoch else {
            return .eventStreamUncertain
        }
        guard
            registration.observedAncestorAmbiguityEpoch
                == barrier.observedAncestorAmbiguityEpoch
        else {
            return .eventStreamUncertain
        }
        return nil
    }

    private func authorityFailureReasonIgnoringAncestorAmbiguity(
        _ authority: GitCleanContinuityAuthority
    ) -> GitCleanContinuityFailureReason? {
        guard !hasShutdown else { return .shutdown }
        guard let registration = registrationById[authority.registrationId] else {
            return .registrationMissing
        }
        guard registration.identity == authority.observationIdentity else {
            return .identityChanged
        }
        guard registration.generation == authority.registrationGeneration else {
            return .registrationReplaced
        }
        guard registration.mutationEpoch == authority.mutationEpoch else {
            return .mutationObserved
        }
        guard registration.uncertaintyEpoch == authority.uncertaintyEpoch else {
            return .eventStreamUncertain
        }
        guard authority.resolvedAncestorAmbiguityEpoch <= registration.resolvedAncestorAmbiguityEpoch else {
            return .eventStreamUncertain
        }
        return nil
    }

    private static func applyRawEvent(
        eventId: FSEventStreamEventId,
        flags: FSEventStreamEventFlags,
        hasRelevantMutation: Bool,
        to registration: inout RegistrationState
    ) {
        let cursorRegressed = registration.latestEventId.map { eventId < $0 } ?? false
        if flags & uncertaintyFlags != 0 || cursorRegressed {
            registration.uncertaintyEpoch &+= 1
        }
        if hasRelevantMutation {
            registration.mutationEpoch &+= 1
        }
        registration.latestEventId = eventId
    }
}

package protocol GitCleanContinuityWitness: Sendable {
    func prepare(
        worktreeId: UUID,
        rootPath: URL,
        observationPlan: AgentStudioGit.GitStatusObservationPlan
    ) async -> GitCleanContinuityPrepareOutcome
    func commit(_ barrier: GitCleanContinuityBarrier) async -> GitCleanContinuityAuthorityValidation
    func renew(_ authority: GitCleanContinuityAuthority) async -> GitCleanContinuityAuthorityValidation
    func retire(worktreeId: UUID, rootPath: URL)
}
