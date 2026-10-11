import CoreServices
import Foundation

package struct DarwinSharedLocalFSEventObservationSnapshot: Equatable, Sendable {
    package let physicalStreamCount: Int
    package let logicalRegistrationCount: Int
    package let physicalStreamCountByVolume: [UInt64: Int]
    package let logicalGenerationsByWorktreeID: [UUID: Set<UInt64>]
    package let hasPendingPhysicalReplacement: Bool
}

private struct DarwinSharedLocalFSEventRegistrationKey: Hashable, Sendable {
    let worktreeID: UUID
    let lifecycleGeneration: UInt64
}

private final class DarwinSharedLocalFSEventRegistration: @unchecked Sendable {
    let watchedPaths: [DarwinSharedLocalFSEventPreparedPath]
    let privateStagingExclusionPaths: [DarwinSharedLocalFSEventPreparedPath]
    private let eventHandler: @Sendable ([DarwinLocalFSEventRawEvent]) -> Void
    private let admissionLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private var hasClosedDeliveryAdmission = false

    init(
        watchedPaths: [DarwinSharedLocalFSEventPreparedPath],
        privateStagingExclusionPaths: [DarwinSharedLocalFSEventPreparedPath],
        eventHandler: @escaping @Sendable ([DarwinLocalFSEventRawEvent]) -> Void
    ) {
        self.watchedPaths = watchedPaths
        self.privateStagingExclusionPaths = privateStagingExclusionPaths
        self.eventHandler = eventHandler
    }

    func closeDeliveryAdmission() {
        admissionLock.withLock { hasClosedDeliveryAdmission = true }
    }

    func waitForDeliveryCompletion() {
        // A handler may retire its own lease. External retirement joins the
        // entered callback; recursive retirement closes future admission.
        deliveryLock.lock()
        deliveryLock.unlock()
    }

    func deliver(_ events: [DarwinLocalFSEventRawEvent]) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard admissionLock.withLock({ !hasClosedDeliveryAdmission }) else { return }
        eventHandler(events)
    }
}

private struct DarwinSharedLocalFSEventObserver: @unchecked Sendable {
    let generation: UInt64
    let watchedPaths: [DarwinSharedLocalFSEventPreparedPath]
    let watchedPathIndex: DarwinFSEventWatchedPathIndex
    var privateStagingPathIndex: DarwinFSEventWatchedPathIndex
    let streamLifetime: any DarwinLocalFSEventStreamLifetime
    var registrationKeys: Set<DarwinSharedLocalFSEventRegistrationKey>
    var registrationKeysByWatchedPath: [String: Set<DarwinSharedLocalFSEventRegistrationKey>]
}

/// Inputs one `bind` computes under `configurationLock` before choosing to
/// join the current physical stream or replace it.
private struct DarwinSharedLocalFSEventBindingPlan: @unchecked Sendable {
    let request: DarwinLocalFSEventStreamRequest
    let registrationKey: DarwinSharedLocalFSEventRegistrationKey
    let registration: DarwinSharedLocalFSEventRegistration
    let volumeSystemNumber: UInt64
    let existingObserver: DarwinSharedLocalFSEventObserver?
    let replacedRegistrationKeys: Set<DarwinSharedLocalFSEventRegistrationKey>
    let desiredWatchedPaths: [DarwinSharedLocalFSEventPreparedPath]
    let desiredExclusionPaths: [DarwinSharedLocalFSEventPreparedPath]
}

private struct DarwinSharedLocalFSEventBindingState: @unchecked Sendable {
    let mayBind: Bool
    let existingObserver: DarwinSharedLocalFSEventObserver?
    let retainedRegistrationKeys: Set<DarwinSharedLocalFSEventRegistrationKey>
    let retainedRegistrations: [DarwinSharedLocalFSEventRegistration]
}

private struct DarwinSharedLocalFSEventRoutingSnapshot: @unchecked Sendable {
    let physicalObserver: DarwinSharedLocalFSEventObserver
    let registrationsByKey: [DarwinSharedLocalFSEventRegistrationKey: DarwinSharedLocalFSEventRegistration]
}

private enum DarwinSharedLocalFSEventRoutingState: @unchecked Sendable {
    case awaitingInstallation
    case awaitingReplay(DarwinSharedLocalFSEventRoutingSnapshot)
    case ready(DarwinSharedLocalFSEventRoutingSnapshot)

    func replacingSnapshot(_ snapshot: DarwinSharedLocalFSEventRoutingSnapshot) -> Self {
        if case .ready = self { return .ready(snapshot) }
        return .awaitingReplay(snapshot)
    }
}

/// The existing generation buffer retains its routing meaning until replay
/// finishes, even when a concurrent bind installs another physical generation.
private struct DarwinSharedLocalFSEventPendingGeneration: @unchecked Sendable {
    let volumeSystemNumber: UInt64
    var bufferedEvents: [DarwinLocalFSEventRawEvent] = []
    var routingState = DarwinSharedLocalFSEventRoutingState.awaitingInstallation
}

private struct DarwinSharedLocalFSEventBindingOutcome: @unchecked Sendable {
    let registrationLease: any DarwinLocalFSEventStreamLifetime
    let replayGeneration: UInt64?
    let replacedRegistrations: [DarwinSharedLocalFSEventRegistration]
}

private enum DarwinSharedLocalFSEventReceiveDisposition: @unchecked Sendable {
    case noDelivery
    case drain
    case deliver(DarwinSharedLocalFSEventRoutingSnapshot)
}

/// Owns a bounded set of physical local FSEvents streams while preserving
/// independent logical registrations for worktree routing and continuity.
package final class DarwinSharedLocalFSEventObserverRegistry: @unchecked Sendable {
    private let configurationLock = NSLock()
    private let stateLock = NSLock()
    private let streamFactory: DarwinLocalFSEventStreamFactory
    private let recordPhysicalRawCallback: @Sendable (Int) -> Void
    private let normalizePath: @Sendable (String) -> String

    private var hasShutdown = false
    private var nextPhysicalGeneration: UInt64 = 0
    private var observerByVolume: [UInt64: DarwinSharedLocalFSEventObserver] = [:]
    private var registrationByKey: [DarwinSharedLocalFSEventRegistrationKey: DarwinSharedLocalFSEventRegistration] = [:]
    private var volumeByRegistrationKey: [DarwinSharedLocalFSEventRegistrationKey: UInt64] = [:]
    private var pendingGenerationByVolume: [UInt64: UInt64] = [:]
    private var pendingDeliveryByGeneration: [UInt64: DarwinSharedLocalFSEventPendingGeneration] = [:]
    private var drainingVolumes: Set<UInt64> = []

    package init(
        streamFactory: @escaping DarwinLocalFSEventStreamFactory,
        recordPhysicalRawCallback: @escaping @Sendable (Int) -> Void,
        normalizePath: @escaping @Sendable (String) -> String =
            DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath
    ) {
        self.streamFactory = streamFactory
        self.recordPhysicalRawCallback = recordPhysicalRawCallback
        self.normalizePath = normalizePath
    }

    deinit {
        shutdown()
    }

    package func bind(
        request: DarwinLocalFSEventStreamRequest
    ) -> (any DarwinLocalFSEventStreamLifetime)? {
        guard
            let volumeSystemNumber = request.watchedPaths.first.flatMap(
                DarwinFSEventBindingPlanner.volumeSystemNumber(for:)
            )
        else {
            return nil
        }

        configurationLock.lock()
        let outcome = bindAssumingConfigurationLock(request: request, volumeSystemNumber: volumeSystemNumber)
        configurationLock.unlock()
        guard let outcome else { return nil }
        for registration in outcome.replacedRegistrations {
            registration.waitForDeliveryCompletion()
        }
        if let generation = outcome.replayGeneration {
            beginReplay(physicalGeneration: generation, volumeSystemNumber: volumeSystemNumber)
        }
        return outcome.registrationLease
    }

    /// Only configuration and installation run under this lock. Replay owns
    /// no configuration lock, so another bind can publish a consistent successor.
    private func bindAssumingConfigurationLock(
        request: DarwinLocalFSEventStreamRequest,
        volumeSystemNumber: UInt64
    ) -> DarwinSharedLocalFSEventBindingOutcome? {

        let registrationKey = DarwinSharedLocalFSEventRegistrationKey(
            worktreeID: request.worktreeId,
            lifecycleGeneration: request.lifecycleGeneration
        )
        let registration = DarwinSharedLocalFSEventRegistration(
            watchedPaths: DarwinSharedLocalFSEventPreparedPath.prepareDistinct(
                request.watchedPaths,
                normalizePath: normalizePath
            ),
            privateStagingExclusionPaths: DarwinSharedLocalFSEventPreparedPath.prepareDistinct(
                request.privateStagingExclusionPaths,
                normalizePath: normalizePath
            ),
            eventHandler: request.eventHandler
        )

        let bindingState = stateLock.withLock { () -> DarwinSharedLocalFSEventBindingState in
            let existingObserver = observerByVolume[volumeSystemNumber]
            let newestExistingGeneration = registrationByKey.keys
                .filter { $0.worktreeID == registrationKey.worktreeID }
                .map(\.lifecycleGeneration)
                .max()
            let candidateIsNewest =
                newestExistingGeneration.map {
                    $0 < registrationKey.lifecycleGeneration
                } ?? true
            let retainedRegistrationKeys = Set(
                existingObserver?.registrationKeys.filter {
                    $0.worktreeID != registrationKey.worktreeID
                } ?? []
            )
            return DarwinSharedLocalFSEventBindingState(
                mayBind: !hasShutdown
                    && registrationByKey[registrationKey] == nil
                    && candidateIsNewest,
                existingObserver: existingObserver,
                retainedRegistrationKeys: retainedRegistrationKeys,
                retainedRegistrations: retainedRegistrationKeys.compactMap { registrationByKey[$0] }
            )
        }
        guard bindingState.mayBind else { return nil }
        let existingObserver = bindingState.existingObserver
        let replacedRegistrationKeys = Set(existingObserver?.registrationKeys ?? [])
            .subtracting(bindingState.retainedRegistrationKeys)

        let desiredWatchedPaths = DarwinSharedLocalFSEventPreparedPath.distinct(
            bindingState.retainedRegistrations.flatMap(\.watchedPaths) + registration.watchedPaths
        )
        let desiredExclusionPaths = Array(
            Set(bindingState.retainedRegistrations.flatMap(\.privateStagingExclusionPaths))
                .union(registration.privateStagingExclusionPaths)
        ).sorted { $0.normalizedPath < $1.normalizedPath }

        let bindingPlan = DarwinSharedLocalFSEventBindingPlan(
            request: request,
            registrationKey: registrationKey,
            registration: registration,
            volumeSystemNumber: volumeSystemNumber,
            existingObserver: existingObserver,
            replacedRegistrationKeys: replacedRegistrationKeys,
            desiredWatchedPaths: desiredWatchedPaths,
            desiredExclusionPaths: desiredExclusionPaths
        )
        if let existingObserver,
            existingObserver.watchedPaths == desiredWatchedPaths
        {
            return joinObserverWithUnchangedPaths(existingObserver, plan: bindingPlan)
        }
        return replacePhysicalObserver(plan: bindingPlan)
    }

    /// Caller holds `configurationLock`.
    private func joinObserverWithUnchangedPaths(
        _ existingObserver: DarwinSharedLocalFSEventObserver,
        plan: DarwinSharedLocalFSEventBindingPlan
    ) -> DarwinSharedLocalFSEventBindingOutcome? {
        var joinedObserver = existingObserver
        joinedObserver.registrationKeys.subtract(plan.replacedRegistrationKeys)
        joinedObserver.registrationKeys.insert(plan.registrationKey)
        joinedObserver.privateStagingPathIndex = DarwinFSEventWatchedPathIndex(
            normalizedPaths: plan.desiredExclusionPaths.map(\.normalizedPath)
        )
        var replacedRegistrations: [DarwinSharedLocalFSEventRegistration] = []
        let installed = stateLock.withLock { () -> Bool in
            guard !hasShutdown else { return false }
            replacedRegistrations = removeRegistrationsAssumingStateLock(plan.replacedRegistrationKeys)
            registrationByKey[plan.registrationKey] = plan.registration
            volumeByRegistrationKey[plan.registrationKey] = plan.volumeSystemNumber
            joinedObserver.registrationKeysByWatchedPath = Self.makeRegistrationPathLookup(
                registrationKeys: joinedObserver.registrationKeys, registrations: registrationByKey
            )
            observerByVolume[plan.volumeSystemNumber] = joinedObserver
            updateRoutingSnapshotAssumingStateLock(joinedObserver)
            return true
        }
        guard installed else { return nil }
        return DarwinSharedLocalFSEventBindingOutcome(
            registrationLease: DarwinSharedLocalFSEventRegistrationLease(
                registry: self, registrationKey: plan.registrationKey, registration: plan.registration
            ),
            replayGeneration: nil,
            replacedRegistrations: replacedRegistrations
        )
    }

    /// Caller holds `configurationLock`. Starts a replacement physical stream
    /// for the widened path set, drains the predecessor, and installs the
    /// replacement atomically. The caller starts replay after unlocking.
    private func replacePhysicalObserver(
        plan: DarwinSharedLocalFSEventBindingPlan
    ) -> DarwinSharedLocalFSEventBindingOutcome? {
        let volumeSystemNumber = plan.volumeSystemNumber
        let existingObserver = plan.existingObserver
        let physicalGeneration = stateLock.withLock { () -> UInt64 in
            nextPhysicalGeneration &+= 1
            let generation = nextPhysicalGeneration
            pendingGenerationByVolume[volumeSystemNumber] = generation
            pendingDeliveryByGeneration[generation] = DarwinSharedLocalFSEventPendingGeneration(
                volumeSystemNumber: volumeSystemNumber
            )
            return generation
        }
        let physicalRequest = DarwinLocalFSEventStreamRequest(
            worktreeId: plan.request.worktreeId,
            lifecycleGeneration: physicalGeneration,
            watchedPaths: plan.desiredWatchedPaths.map(\.normalizedPath),
            // A physical stream can cover more than eight repositories, while
            // FSEventStreamSetExclusionPaths accepts at most eight paths.
            // Contract Agent Studio's private staged refs once in `receive`
            // instead of making native stream availability depend on repo count.
            privateStagingExclusionPaths: [],
            eventHandler: { [weak self] rawEvents in
                self?.receive(
                    volumeSystemNumber: volumeSystemNumber,
                    physicalGeneration: physicalGeneration,
                    rawEvents: rawEvents
                )
            }
        )
        guard let replacementLifetime = streamFactory(physicalRequest) else {
            clearPendingGeneration(
                physicalGeneration,
                volumeSystemNumber: volumeSystemNumber
            )
            return nil
        }

        // The replacement begins at `sinceNow`. Flush the still-current
        // predecessor before installing it: events before replacement start
        // drain through the predecessor, while replacement callbacks buffer
        // until the atomic handoff below.
        if let existingObserver, !existingObserver.streamLifetime.flush() {
            replacementLifetime.retire()
            clearPendingGeneration(
                physicalGeneration,
                volumeSystemNumber: volumeSystemNumber
            )
            return nil
        }

        var retiredLifetime: (any DarwinLocalFSEventStreamLifetime)?
        var replacedRegistrations: [DarwinSharedLocalFSEventRegistration] = []
        let installed = stateLock.withLock { () -> Bool in
            guard !hasShutdown,
                pendingGenerationByVolume[volumeSystemNumber] == physicalGeneration
            else {
                pendingDeliveryByGeneration.removeValue(forKey: physicalGeneration)
                return false
            }
            replacedRegistrations = removeRegistrationsAssumingStateLock(plan.replacedRegistrationKeys)
            registrationByKey[plan.registrationKey] = plan.registration
            volumeByRegistrationKey[plan.registrationKey] = volumeSystemNumber
            var registrationKeys =
                existingObserver?.registrationKeys.subtracting(
                    plan.replacedRegistrationKeys
                ) ?? []
            registrationKeys.insert(plan.registrationKey)
            retiredLifetime = existingObserver?.streamLifetime
            let installedObserver = DarwinSharedLocalFSEventObserver(
                generation: physicalGeneration,
                watchedPaths: plan.desiredWatchedPaths,
                watchedPathIndex: DarwinFSEventWatchedPathIndex(
                    normalizedPaths: plan.desiredWatchedPaths.map(\.normalizedPath)
                ),
                privateStagingPathIndex: DarwinFSEventWatchedPathIndex(
                    normalizedPaths: plan.desiredExclusionPaths.map(\.normalizedPath)
                ),
                streamLifetime: replacementLifetime,
                registrationKeys: registrationKeys,
                registrationKeysByWatchedPath: Self.makeRegistrationPathLookup(
                    registrationKeys: registrationKeys, registrations: registrationByKey
                )
            )
            observerByVolume[volumeSystemNumber] = installedObserver
            updateRoutingSnapshotAssumingStateLock(installedObserver)
            return true
        }
        guard installed else {
            replacementLifetime.retire()
            return nil
        }
        retiredLifetime?.retire()
        return DarwinSharedLocalFSEventBindingOutcome(
            registrationLease: DarwinSharedLocalFSEventRegistrationLease(
                registry: self, registrationKey: plan.registrationKey, registration: plan.registration
            ),
            replayGeneration: physicalGeneration,
            replacedRegistrations: replacedRegistrations
        )
    }

    package func snapshot() -> DarwinSharedLocalFSEventObservationSnapshot {
        stateLock.withLock {
            DarwinSharedLocalFSEventObservationSnapshot(
                physicalStreamCount: observerByVolume.count,
                logicalRegistrationCount: registrationByKey.count,
                physicalStreamCountByVolume: Dictionary(
                    uniqueKeysWithValues: observerByVolume.keys.map { ($0, 1) }
                ),
                logicalGenerationsByWorktreeID: Dictionary(
                    grouping: registrationByKey.keys,
                    by: \.worktreeID
                ).mapValues { Set($0.map(\.lifecycleGeneration)) },
                hasPendingPhysicalReplacement: !pendingGenerationByVolume.isEmpty
            )
        }
    }

    package func flushAllPhysicalStreams() -> Bool {
        let retainedObservers = stateLock.withLock { () -> [(UInt64, UInt64, any DarwinLocalFSEventStreamLifetime)]? in
            guard !hasShutdown else { return nil }
            return observerByVolume.map { volumeSystemNumber, observer in
                (volumeSystemNumber, observer.generation, observer.streamLifetime)
            }
        }
        guard let retainedObservers else { return false }
        for (volumeSystemNumber, generation, streamLifetime) in retainedObservers {
            guard streamLifetime.flush() else { return false }
            guard
                stateLock.withLock({
                    !hasShutdown && observerByVolume[volumeSystemNumber]?.generation == generation
                })
            else {
                return false
            }
        }
        return true
    }

    package func shutdown() {
        configurationLock.lock()
        let retirementState = stateLock.withLock {
            () -> ([any DarwinLocalFSEventStreamLifetime], [DarwinSharedLocalFSEventRegistration]) in
            guard !hasShutdown else { return ([], []) }
            hasShutdown = true
            let lifetimes = observerByVolume.values.map(\.streamLifetime)
            let registrations = Array(registrationByKey.values)
            for registration in registrations { registration.closeDeliveryAdmission() }
            observerByVolume.removeAll(keepingCapacity: false)
            registrationByKey.removeAll(keepingCapacity: false)
            volumeByRegistrationKey.removeAll(keepingCapacity: false)
            pendingGenerationByVolume.removeAll(keepingCapacity: false)
            pendingDeliveryByGeneration.removeAll(keepingCapacity: false)
            drainingVolumes.removeAll(keepingCapacity: false)
            return (lifetimes, registrations)
        }
        configurationLock.unlock()
        for registration in retirementState.1 { registration.waitForDeliveryCompletion() }
        for streamLifetime in retirementState.0 {
            streamLifetime.retire()
        }
    }

    fileprivate func flush(
        registrationKey: DarwinSharedLocalFSEventRegistrationKey
    ) -> Bool {
        let retainedObserver = stateLock.withLock {
            guard !hasShutdown,
                registrationByKey[registrationKey] != nil,
                let volumeSystemNumber = volumeByRegistrationKey[registrationKey],
                let observer = observerByVolume[volumeSystemNumber]
            else {
                return Optional<(UInt64, UInt64, any DarwinLocalFSEventStreamLifetime)>.none
            }
            return (volumeSystemNumber, observer.generation, observer.streamLifetime)
        }
        guard let (volumeSystemNumber, generation, streamLifetime) = retainedObserver,
            streamLifetime.flush()
        else {
            return false
        }
        return stateLock.withLock {
            !hasShutdown
                && registrationByKey[registrationKey] != nil
                && volumeByRegistrationKey[registrationKey] == volumeSystemNumber
                && observerByVolume[volumeSystemNumber]?.generation == generation
        }
    }

    fileprivate func unbind(
        registrationKey: DarwinSharedLocalFSEventRegistrationKey
    ) {
        configurationLock.lock()
        var retiredLifetime: (any DarwinLocalFSEventStreamLifetime)?
        var retiredRegistration: DarwinSharedLocalFSEventRegistration?
        stateLock.withLock {
            guard let volumeSystemNumber = volumeByRegistrationKey.removeValue(forKey: registrationKey) else {
                return
            }
            retiredRegistration = registrationByKey.removeValue(forKey: registrationKey)
            retiredRegistration?.closeDeliveryAdmission()
            guard var observer = observerByVolume[volumeSystemNumber] else { return }
            observer.registrationKeys.remove(registrationKey)
            for watchedPath in retiredRegistration?.watchedPaths ?? [] {
                observer.registrationKeysByWatchedPath[watchedPath.normalizedPath]?.remove(registrationKey)
                if observer.registrationKeysByWatchedPath[watchedPath.normalizedPath]?.isEmpty == true {
                    observer.registrationKeysByWatchedPath.removeValue(forKey: watchedPath.normalizedPath)
                }
            }
            if observer.registrationKeys.isEmpty {
                observerByVolume.removeValue(forKey: volumeSystemNumber)
                retiredLifetime = observer.streamLifetime
                pendingGenerationByVolume.removeValue(forKey: volumeSystemNumber)
                let generations = pendingDeliveryByGeneration.filter {
                    $0.value.volumeSystemNumber == volumeSystemNumber
                }.keys
                for generation in generations { pendingDeliveryByGeneration.removeValue(forKey: generation) }
            } else {
                observerByVolume[volumeSystemNumber] = observer
                updateRoutingSnapshotAssumingStateLock(observer)
            }
        }
        configurationLock.unlock()
        retiredRegistration?.waitForDeliveryCompletion()
        retiredLifetime?.retire()
    }

    fileprivate func scheduleUnbind(
        registrationKey: DarwinSharedLocalFSEventRegistrationKey
    ) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.unbind(registrationKey: registrationKey)
        }
    }

    private func clearPendingGeneration(
        _ generation: UInt64,
        volumeSystemNumber: UInt64
    ) {
        stateLock.withLock {
            if pendingGenerationByVolume[volumeSystemNumber] == generation {
                pendingGenerationByVolume.removeValue(forKey: volumeSystemNumber)
            }
            pendingDeliveryByGeneration.removeValue(forKey: generation)
        }
    }

    private func updateRoutingSnapshotAssumingStateLock(_ observer: DarwinSharedLocalFSEventObserver) {
        guard let routingState = pendingDeliveryByGeneration[observer.generation]?.routingState else { return }
        let snapshot = DarwinSharedLocalFSEventRoutingSnapshot(
            physicalObserver: observer, registrationsByKey: registrationByKey
        )
        pendingDeliveryByGeneration[observer.generation]?.routingState = routingState.replacingSnapshot(snapshot)
    }

    private func beginReplay(physicalGeneration: UInt64, volumeSystemNumber: UInt64) {
        let shouldDrain = stateLock.withLock { () -> Bool in
            guard !hasShutdown,
                let routingState = pendingDeliveryByGeneration[physicalGeneration]?.routingState,
                case .awaitingReplay(let snapshot) = routingState
            else { return false }
            pendingDeliveryByGeneration[physicalGeneration]?.routingState = .ready(snapshot)
            return claimDrainAssumingStateLock(volumeSystemNumber)
        }
        if shouldDrain { drainPendingBatches(volumeSystemNumber: volumeSystemNumber) }
    }

    private func claimDrainAssumingStateLock(_ volumeSystemNumber: UInt64) -> Bool {
        !hasShutdown && drainingVolumes.insert(volumeSystemNumber).inserted
    }

    private func drainPendingBatches(volumeSystemNumber: UInt64) {
        while let (snapshot, events) = takeNextPendingBatch(volumeSystemNumber: volumeSystemNumber) {
            deliver(snapshot: snapshot, rawEvents: events)
        }
    }

    private func takeNextPendingBatch(
        volumeSystemNumber: UInt64
    ) -> (DarwinSharedLocalFSEventRoutingSnapshot, [DarwinLocalFSEventRawEvent])? {
        stateLock.withLock {
            guard !hasShutdown else {
                drainingVolumes.remove(volumeSystemNumber)
                return nil
            }
            let generations = pendingDeliveryByGeneration.filter { $0.value.volumeSystemNumber == volumeSystemNumber }
                .keys.sorted()
            for generation in generations {
                guard let pending = pendingDeliveryByGeneration[generation] else { continue }
                guard case .ready(let snapshot) = pending.routingState else {
                    // A later binder may finish first. Its callbacks cannot
                    // overtake the earlier binder's still-unarmed handoff.
                    drainingVolumes.remove(volumeSystemNumber)
                    return nil
                }
                if !pending.bufferedEvents.isEmpty {
                    pendingDeliveryByGeneration[generation]?.bufferedEvents = []
                    return (snapshot, pending.bufferedEvents)
                }
                if observerByVolume[volumeSystemNumber]?.generation != generation {
                    pendingDeliveryByGeneration.removeValue(forKey: generation)
                }
                if pendingGenerationByVolume[volumeSystemNumber] == generation {
                    pendingGenerationByVolume.removeValue(forKey: volumeSystemNumber)
                }
            }
            // Release ownership atomically with observing no runnable batch.
            // A callback arriving next can claim it without a lost wake-up.
            drainingVolumes.remove(volumeSystemNumber)
            return nil
        }
    }

    private func receive(
        volumeSystemNumber: UInt64,
        physicalGeneration: UInt64,
        rawEvents: [DarwinLocalFSEventRawEvent]
    ) {
        guard !rawEvents.isEmpty else { return }
        recordPhysicalRawCallback(rawEvents.count)

        let disposition = stateLock.withLock { () -> DarwinSharedLocalFSEventReceiveDisposition in
            guard !hasShutdown,
                pendingGenerationByVolume[volumeSystemNumber] == physicalGeneration
                    || observerByVolume[volumeSystemNumber]?.generation == physicalGeneration,
                let routingState = pendingDeliveryByGeneration[physicalGeneration]?.routingState
            else { return .noDelivery }
            if pendingGenerationByVolume[volumeSystemNumber] == physicalGeneration
                || drainingVolumes.contains(volumeSystemNumber)
            {
                // Mutate the existing buffer in place: do not copy a growing
                // backlog on every callback while a replay is in progress.
                pendingDeliveryByGeneration[physicalGeneration]?.bufferedEvents.append(contentsOf: rawEvents)
                if case .ready = routingState, claimDrainAssumingStateLock(volumeSystemNumber) {
                    return .drain
                }
                return .noDelivery
            }
            guard case .ready(let snapshot) = routingState,
                claimDrainAssumingStateLock(volumeSystemNumber)
            else { return .noDelivery }
            return .deliver(snapshot)
        }
        switch disposition {
        case .noDelivery: return
        case .drain: drainPendingBatches(volumeSystemNumber: volumeSystemNumber)
        case .deliver(let snapshot):
            // Ordinary callbacks keep their existing serial execution path.
            // Any ready replacement replay follows their closing delivery.
            deliver(snapshot: snapshot, rawEvents: rawEvents)
            drainPendingBatches(volumeSystemNumber: volumeSystemNumber)
        }
    }

    private func deliver(
        snapshot: DarwinSharedLocalFSEventRoutingSnapshot,
        rawEvents: [DarwinLocalFSEventRawEvent]
    ) {
        let observer = snapshot.physicalObserver
        let registrations = snapshot.registrationsByKey
        var eventsByRegistration: [DarwinSharedLocalFSEventRegistrationKey: [DarwinLocalFSEventRawEvent]] = [:]
        for event in rawEvents {
            let normalizedPath = normalizePath(event.path)
            guard
                Self.bypassesPrivateStagingFilter(event)
                    || !observer.privateStagingPathIndex.containsAncestor(of: normalizedPath)
            else { continue }
            let matchingKeys: Set<DarwinSharedLocalFSEventRegistrationKey>
            if Self.isStreamGlobalUncertainty(event) {
                matchingKeys = observer.registrationKeys
            } else {
                let matchingPaths =
                    event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                    ? observer.watchedPathIndex.descendants(of: normalizedPath)
                    : observer.watchedPathIndex.intersectingPaths(with: normalizedPath)
                matchingKeys = matchingPaths.reduce(into: []) { keys, watchedPath in
                    keys.formUnion(observer.registrationKeysByWatchedPath[watchedPath] ?? [])
                }
            }
            for registrationKey in matchingKeys where registrations[registrationKey] != nil {
                eventsByRegistration[registrationKey, default: []].append(event)
            }
        }
        for (registrationKey, matchingEvents) in eventsByRegistration {
            registrations[registrationKey]?.deliver(matchingEvents)
        }
    }

    private static func isStreamGlobalUncertainty(
        _ event: DarwinLocalFSEventRawEvent
    ) -> Bool {
        event.flags & streamGlobalUncertaintyFlags != 0
    }

    private static func bypassesPrivateStagingFilter(
        _ event: DarwinLocalFSEventRawEvent
    ) -> Bool {
        event.flags & controlEventFlags != 0
    }

    private static func makeRegistrationPathLookup(
        registrationKeys: Set<DarwinSharedLocalFSEventRegistrationKey>,
        registrations: [DarwinSharedLocalFSEventRegistrationKey: DarwinSharedLocalFSEventRegistration]
    ) -> [String: Set<DarwinSharedLocalFSEventRegistrationKey>] {
        var lookup: [String: Set<DarwinSharedLocalFSEventRegistrationKey>] = [:]
        for registrationKey in registrationKeys {
            for path in registrations[registrationKey]?.watchedPaths ?? [] {
                lookup[path.normalizedPath, default: []].insert(registrationKey)
            }
        }
        return lookup
    }

    private func removeRegistrationsAssumingStateLock(
        _ registrationKeys: Set<DarwinSharedLocalFSEventRegistrationKey>
    ) -> [DarwinSharedLocalFSEventRegistration] {
        var removedRegistrations: [DarwinSharedLocalFSEventRegistration] = []
        for registrationKey in registrationKeys {
            if let registration = registrationByKey.removeValue(forKey: registrationKey) {
                // Closing admission never waits for the opaque handler while
                // state/configuration locks are held. Joining happens outside.
                registration.closeDeliveryAdmission()
                removedRegistrations.append(registration)
            }
            volumeByRegistrationKey.removeValue(forKey: registrationKey)
        }
        return removedRegistrations
    }

    private static let streamGlobalUncertaintyFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
    )

    private static let controlEventFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
    )
}

private final class DarwinSharedLocalFSEventRegistrationLease:
    DarwinLocalFSEventStreamLifetime, @unchecked Sendable
{
    private let retirementLock = NSLock()
    private weak var registry: DarwinSharedLocalFSEventObserverRegistry?
    private weak var registration: DarwinSharedLocalFSEventRegistration?
    private let registrationKey: DarwinSharedLocalFSEventRegistrationKey
    private var didRetire = false

    init(
        registry: DarwinSharedLocalFSEventObserverRegistry,
        registrationKey: DarwinSharedLocalFSEventRegistrationKey,
        registration: DarwinSharedLocalFSEventRegistration
    ) {
        self.registry = registry
        self.registrationKey = registrationKey
        self.registration = registration
    }

    deinit {
        retire()
    }

    func flush() -> Bool {
        guard retirementLock.withLock({ !didRetire }) else { return false }
        return registry?.flush(registrationKey: registrationKey) == true
    }

    func retire() {
        if claimRetirement() {
            let retainedRegistration = registration
            retainedRegistration?.closeDeliveryAdmission()
            registry?.unbind(registrationKey: registrationKey)
            // A newer bind may already have removed this key. The lease still
            // joins a captured old handler without retaining it permanently.
            retainedRegistration?.waitForDeliveryCompletion()
        }
    }

    func scheduleRetirement() {
        if claimRetirement() {
            registration?.closeDeliveryAdmission()
            registry?.scheduleUnbind(registrationKey: registrationKey)
        }
    }

    private func claimRetirement() -> Bool {
        retirementLock.withLock {
            guard !didRetire else { return false }
            didRetire = true
            return true
        }
    }
}
