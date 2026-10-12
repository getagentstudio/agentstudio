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

private struct DarwinSharedLocalFSEventRegistration: @unchecked Sendable {
    let watchedPaths: [DarwinSharedLocalFSEventPreparedPath]
    let privateStagingExclusionPaths: [DarwinSharedLocalFSEventPreparedPath]
    let eventHandler: @Sendable ([DarwinLocalFSEventRawEvent]) -> Void
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
    private var pendingEventsByGeneration: [UInt64: [DarwinLocalFSEventRawEvent]] = [:]

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
        defer { configurationLock.unlock() }

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
    ) -> (any DarwinLocalFSEventStreamLifetime)? {
        var joinedObserver = existingObserver
        joinedObserver.registrationKeys.subtract(plan.replacedRegistrationKeys)
        joinedObserver.registrationKeys.insert(plan.registrationKey)
        joinedObserver.privateStagingPathIndex = DarwinFSEventWatchedPathIndex(
            normalizedPaths: plan.desiredExclusionPaths.map(\.normalizedPath)
        )
        stateLock.withLock {
            guard !hasShutdown else { return }
            removeRegistrationsAssumingStateLock(plan.replacedRegistrationKeys)
            registrationByKey[plan.registrationKey] = plan.registration
            volumeByRegistrationKey[plan.registrationKey] = plan.volumeSystemNumber
            joinedObserver.registrationKeysByWatchedPath = Self.makeRegistrationPathLookup(
                registrationKeys: joinedObserver.registrationKeys, registrations: registrationByKey
            )
            observerByVolume[plan.volumeSystemNumber] = joinedObserver
        }
        guard stateLock.withLock({ registrationByKey[plan.registrationKey] != nil }) else {
            return nil
        }
        return DarwinSharedLocalFSEventRegistrationLease(
            registry: self,
            registrationKey: plan.registrationKey
        )
    }

    /// Caller holds `configurationLock`. Starts a replacement physical stream
    /// for the widened path set, drains the predecessor, and installs the
    /// replacement atomically.
    private func replacePhysicalObserver(
        plan: DarwinSharedLocalFSEventBindingPlan
    ) -> (any DarwinLocalFSEventStreamLifetime)? {
        let volumeSystemNumber = plan.volumeSystemNumber
        let existingObserver = plan.existingObserver
        let physicalGeneration = stateLock.withLock { () -> UInt64 in
            nextPhysicalGeneration &+= 1
            let generation = nextPhysicalGeneration
            pendingGenerationByVolume[volumeSystemNumber] = generation
            pendingEventsByGeneration[generation] = []
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
        let installed = stateLock.withLock { () -> Bool in
            guard !hasShutdown,
                pendingGenerationByVolume[volumeSystemNumber] == physicalGeneration
            else {
                pendingEventsByGeneration.removeValue(forKey: physicalGeneration)
                return false
            }
            removeRegistrationsAssumingStateLock(plan.replacedRegistrationKeys)
            registrationByKey[plan.registrationKey] = plan.registration
            volumeByRegistrationKey[plan.registrationKey] = volumeSystemNumber
            var registrationKeys =
                existingObserver?.registrationKeys.subtracting(
                    plan.replacedRegistrationKeys
                ) ?? []
            registrationKeys.insert(plan.registrationKey)
            retiredLifetime = existingObserver?.streamLifetime
            observerByVolume[volumeSystemNumber] = DarwinSharedLocalFSEventObserver(
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
            return true
        }
        guard installed else {
            replacementLifetime.retire()
            return nil
        }
        retiredLifetime?.retire()
        while let bufferedEvents = takeNextPendingBatch(
            physicalGeneration: physicalGeneration,
            volumeSystemNumber: volumeSystemNumber
        ) {
            deliver(
                volumeSystemNumber: volumeSystemNumber,
                physicalGeneration: physicalGeneration,
                rawEvents: bufferedEvents
            )
        }
        return DarwinSharedLocalFSEventRegistrationLease(
            registry: self,
            registrationKey: plan.registrationKey
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
        let streamLifetimes = stateLock.withLock { () -> [any DarwinLocalFSEventStreamLifetime] in
            guard !hasShutdown else { return [] }
            hasShutdown = true
            let lifetimes = observerByVolume.values.map(\.streamLifetime)
            observerByVolume.removeAll(keepingCapacity: false)
            registrationByKey.removeAll(keepingCapacity: false)
            volumeByRegistrationKey.removeAll(keepingCapacity: false)
            pendingGenerationByVolume.removeAll(keepingCapacity: false)
            pendingEventsByGeneration.removeAll(keepingCapacity: false)
            return lifetimes
        }
        configurationLock.unlock()
        for streamLifetime in streamLifetimes {
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
        stateLock.withLock {
            guard let volumeSystemNumber = volumeByRegistrationKey.removeValue(forKey: registrationKey) else {
                return
            }
            registrationByKey.removeValue(forKey: registrationKey)
            guard var observer = observerByVolume[volumeSystemNumber] else { return }
            observer.registrationKeys.remove(registrationKey)
            if observer.registrationKeys.isEmpty {
                observerByVolume.removeValue(forKey: volumeSystemNumber)
                retiredLifetime = observer.streamLifetime
            } else {
                observerByVolume[volumeSystemNumber] = observer
            }
        }
        configurationLock.unlock()
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
            pendingEventsByGeneration.removeValue(forKey: generation)
        }
    }

    private func takeNextPendingBatch(
        physicalGeneration: UInt64,
        volumeSystemNumber: UInt64
    ) -> [DarwinLocalFSEventRawEvent]? {
        stateLock.withLock {
            guard pendingGenerationByVolume[volumeSystemNumber] == physicalGeneration else {
                pendingEventsByGeneration.removeValue(forKey: physicalGeneration)
                return nil
            }
            let pendingEvents = pendingEventsByGeneration[physicalGeneration] ?? []
            if pendingEvents.isEmpty {
                pendingGenerationByVolume.removeValue(forKey: volumeSystemNumber)
                pendingEventsByGeneration.removeValue(forKey: physicalGeneration)
                return nil
            }
            pendingEventsByGeneration[physicalGeneration] = []
            return pendingEvents
        }
    }

    private func receive(
        volumeSystemNumber: UInt64,
        physicalGeneration: UInt64,
        rawEvents: [DarwinLocalFSEventRawEvent]
    ) {
        guard !rawEvents.isEmpty else { return }
        recordPhysicalRawCallback(rawEvents.count)

        let buffered = stateLock.withLock { () -> Bool in
            if pendingGenerationByVolume[volumeSystemNumber] == physicalGeneration {
                pendingEventsByGeneration[physicalGeneration, default: []].append(contentsOf: rawEvents)
                return true
            }
            return false
        }
        guard !buffered else { return }
        deliver(
            volumeSystemNumber: volumeSystemNumber,
            physicalGeneration: physicalGeneration,
            rawEvents: rawEvents
        )
    }

    private func deliver(
        volumeSystemNumber: UInt64,
        physicalGeneration: UInt64,
        rawEvents: [DarwinLocalFSEventRawEvent]
    ) {
        let routingState = stateLock.withLock {
            () -> (
                DarwinSharedLocalFSEventObserver,
                [DarwinSharedLocalFSEventRegistrationKey: DarwinSharedLocalFSEventRegistration]
            )? in
            guard !hasShutdown,
                let observer = observerByVolume[volumeSystemNumber],
                observer.generation == physicalGeneration
            else {
                return nil
            }
            return (observer, registrationByKey)
        }
        guard let (observer, registrations) = routingState else { return }
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
            registrations[registrationKey]?.eventHandler(matchingEvents)
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
    ) {
        for registrationKey in registrationKeys {
            registrationByKey.removeValue(forKey: registrationKey)
            volumeByRegistrationKey.removeValue(forKey: registrationKey)
        }
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
    private let registrationKey: DarwinSharedLocalFSEventRegistrationKey
    private var didRetire = false

    init(
        registry: DarwinSharedLocalFSEventObserverRegistry,
        registrationKey: DarwinSharedLocalFSEventRegistrationKey
    ) {
        self.registry = registry
        self.registrationKey = registrationKey
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
            registry?.unbind(registrationKey: registrationKey)
        }
    }

    func scheduleRetirement() {
        if claimRetirement() {
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
