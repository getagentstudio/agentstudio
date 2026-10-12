import AgentStudioGit
import CoreServices
import Foundation

package struct DarwinSharedExactItemRawEvent: Sendable {
    package let path: String
    package let eventId: FSEventStreamEventId
    package let flags: FSEventStreamEventFlags
}

package struct DarwinFSEventClassifiedRawEvent: Sendable {
    package let path: String
    package let eventId: FSEventStreamEventId
    package let flags: FSEventStreamEventFlags
    package let hasRelevantMutation: Bool

    package init(
        eventId: FSEventStreamEventId,
        flags: FSEventStreamEventFlags,
        hasRelevantMutation: Bool,
        path: String = ""
    ) {
        self.path = path
        self.eventId = eventId
        self.flags = flags
        self.hasRelevantMutation = hasRelevantMutation
    }
}

package struct DarwinFSEventClassification: Sendable {
    package let rawEvents: [DarwinFSEventClassifiedRawEvent]
    package let ordinaryPaths: [String]
}

package enum DarwinFSEventPathClassifier {
    package static func classify(
        rawEvents: [(path: String, eventId: FSEventStreamEventId, flags: FSEventStreamEventFlags)],
        ordinaryPaths: [String],
        rootPath: String,
        observationScopes: [AgentStudioGit.GitStatusObservationScope],
        normalize: (String) -> String = DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath
    ) -> DarwinFSEventClassification {
        var normalizedPathByRawPath: [String: String] = [:]
        normalizedPathByRawPath.reserveCapacity(rawEvents.count)
        var privateStagingDecisionByNormalizedPath: [String: Bool] = [:]
        privateStagingDecisionByNormalizedPath.reserveCapacity(rawEvents.count)

        func normalizedPath(for rawPath: String) -> String {
            if let existing = normalizedPathByRawPath[rawPath] {
                return existing
            }
            let normalizedPath = normalize(rawPath)
            normalizedPathByRawPath[rawPath] = normalizedPath
            return normalizedPath
        }

        func isPrivateStagingRefPath(_ normalizedPath: String) -> Bool {
            if let existing = privateStagingDecisionByNormalizedPath[normalizedPath] {
                return existing
            }
            let isPrivateStagingRef = FilesystemPathFilter.isAgentStudioPrivateStagingRefPath(normalizedPath)
            privateStagingDecisionByNormalizedPath[normalizedPath] = isPrivateStagingRef
            return isPrivateStagingRef
        }

        let canonicalScopes = observationScopes.map { scope in
            let path = scope.path.path
            return (
                kind: scope.kind,
                path: path,
                subtreePrefix: scope.kind == .subtree ? path + "/" : nil
            )
        }
        let rootPrefix = rootPath + "/"
        let classifiedRawEvents = rawEvents.map { event in
            let candidate = normalizedPath(for: event.path)
            let hasRelevantMutation =
                !isPrivateStagingRefPath(candidate)
                && canonicalScopes.contains { scope in
                    switch scope.kind {
                    case .item:
                        return candidate == scope.path
                    case .subtree:
                        return candidate == scope.path
                            || scope.subtreePrefix.map { candidate.hasPrefix($0) } == true
                    }
                }
            return DarwinFSEventClassifiedRawEvent(
                eventId: event.eventId,
                flags: event.flags,
                hasRelevantMutation: hasRelevantMutation,
                path: event.path
            )
        }
        let ordinaryWorktreePaths = ordinaryPaths.filter { path in
            let candidate = normalizedPath(for: path)
            return !isPrivateStagingRefPath(candidate)
                && (candidate == rootPath || candidate.hasPrefix(rootPrefix))
        }
        return DarwinFSEventClassification(
            rawEvents: classifiedRawEvents,
            ordinaryPaths: ordinaryWorktreePaths
        )
    }
}

package protocol DarwinSharedExactItemStreamLifetime: AnyObject, Sendable {
    func flush() -> Bool
    func retire()
}

package typealias DarwinSharedExactItemStreamFactory =
    @Sendable (
        DarwinSharedExactItemParentKey,
        UInt64,
        @escaping @Sendable ([DarwinSharedExactItemRawEvent]) -> Void
    ) -> (any DarwinSharedExactItemStreamLifetime)?

package struct DarwinSharedExactItemObservationSnapshot: Sendable {
    package let observerCount: Int
    package let bindingCount: Int
    package let generationByParent: [DarwinSharedExactItemParentKey: UInt64]
    package let referenceCountByParent: [DarwinSharedExactItemParentKey: Int]
    package let activeRecheckCount: Int
    package let unresolvedRegistrationCount: Int
}

package struct DarwinSharedExactItemBindingLease: Sendable {
    package let bindingGeneration: UInt64
    package let exactItemsByParent: [DarwinSharedExactItemParentKey: Set<String>]
    package let streamGenerationByParent: [DarwinSharedExactItemParentKey: UInt64]
    private let streamLifetimeByParent: [DarwinSharedExactItemParentKey: any DarwinSharedExactItemStreamLifetime]

    fileprivate init(
        bindingGeneration: UInt64,
        exactItemsByParent: [DarwinSharedExactItemParentKey: Set<String>],
        streamGenerationByParent: [DarwinSharedExactItemParentKey: UInt64],
        streamLifetimeByParent:
            [DarwinSharedExactItemParentKey: any DarwinSharedExactItemStreamLifetime]
    ) {
        self.bindingGeneration = bindingGeneration
        self.exactItemsByParent = exactItemsByParent
        self.streamGenerationByParent = streamGenerationByParent
        self.streamLifetimeByParent = streamLifetimeByParent
    }

    package func flush() -> Bool {
        for parentKey in streamLifetimeByParent.keys.sorted(by: Self.sortParentKeys) {
            guard streamLifetimeByParent[parentKey]?.flush() == true else { return false }
        }
        return true
    }

    private static func sortParentKeys(
        _ lhs: DarwinSharedExactItemParentKey,
        _ rhs: DarwinSharedExactItemParentKey
    ) -> Bool {
        if lhs.volumeSystemNumber != rhs.volumeSystemNumber {
            return lhs.volumeSystemNumber < rhs.volumeSystemNumber
        }
        return lhs.parentPath < rhs.parentPath
    }
}

package enum DarwinSharedExactItemBindingRetention: Sendable {
    case localOnly
    case shared(DarwinSharedExactItemBindingLease)
    case invalid
}

package final class DarwinSharedExactItemObserverRegistry: @unchecked Sendable {
    struct BindingValidation: Sendable {
        let generation: UInt64
        let observationIdentity: AgentStudioGit.GitStatusObservationIdentity?
        let isCurrent: @Sendable () -> Bool
    }

    struct ObserverState {
        let generation: UInt64
        let streamLifetime: any DarwinSharedExactItemStreamLifetime
        var exactPathsByWorktreeId: [UUID: Set<String>]
        var worktreeIdsByExactPath: [String: Set<UUID>]
        var latestEventId: FSEventStreamEventId?
        var latestActivitySettledEventId: FSEventStreamEventId?
        var pendingActivityDeliveryCount: Int
        var activeAncestorRecheckGeneration: UInt64?
        var unresolvedAncestorEntriesByWorktreeId: [UUID: DarwinSharedExactItemAncestorUnresolvedEntry]
    }

    private struct StartedObserver {
        let generation: UInt64
        let streamLifetime: any DarwinSharedExactItemStreamLifetime
    }

    private struct ReceiveClassification {
        var mutationEventsByWorktreeId: [UUID: [DarwinFSEventClassifiedRawEvent]] = [:]
        var uncertainWorktreeIds: Set<UUID> = []
        var exactSubscriberWorktreeIds: Set<UUID> = []
        var activityQualifyingWorktreeIds: Set<UUID> = []
        var activityOwnEventWorktreeIds: Set<UUID> = []
        var exactHitWithPendingAncestorWorktreeIds: Set<UUID> = []
        var shouldRetireObserver = false
    }

    private static let uncertaintyFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
    )

    let lifecycleCondition = NSCondition()
    private let streamFactory: DarwinSharedExactItemStreamFactory
    let recordRawEvents: @Sendable (UUID, [DarwinFSEventClassifiedRawEvent]) -> Void
    private let recordAncestorAmbiguity: @Sendable (UUID) -> UInt64?
    let authorityIsCurrentForAncestorRecheck: @Sendable (GitCleanContinuityAuthority) -> Bool
    let currentObservedAncestorAmbiguityEpoch: @Sendable (GitCleanContinuityAuthority) -> UInt64?
    let resolveAncestorAmbiguity:
        @Sendable (GitCleanContinuityAuthority, UInt64) -> GitCleanContinuityAuthorityValidation
    let markUncertain: @Sendable (UUID) -> Void
    let yieldFullGitRefresh: @Sendable (UUID, DarwinFSEventIngressSource) -> Void
    let yieldActivityObservations: @Sendable (FSEventActivityObservationBatch) -> Void
    let performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator
    let fingerprintReader: DarwinSharedExactItemFingerprintReader
    private var nextStreamGeneration: UInt64 = 0
    var nextAncestorRecheckGeneration: UInt64 = 0
    var observerByParent: [DarwinSharedExactItemParentKey: ObserverState] = [:]
    var exactItemsByParentByWorktreeId: [UUID: [DarwinSharedExactItemParentKey: Set<String>]] = [:]
    var bindingValidationByWorktreeId: [UUID: BindingValidation] = [:]
    private var sharedDependentWorktreeIds: Set<UUID> = []
    var fullRefreshDeliveryOutstandingWorktreeIds: Set<UUID> = []
    var authorityBaselines = DarwinSharedExactItemAuthorityBaselines()
    private var startingParentKeys: Set<DarwinSharedExactItemParentKey> = []
    var hasShutdown = false
    private var hasStoppedActivityAdmission = false
    var activityTopologyRevision: UInt64 = 0

    package init(
        streamFactory: @escaping DarwinSharedExactItemStreamFactory,
        recordRawEvents:
            @escaping @Sendable (
                UUID,
                [DarwinFSEventClassifiedRawEvent]
            ) -> Void,
        recordAncestorAmbiguity: @escaping @Sendable (UUID) -> UInt64? = { _ in nil },
        authorityIsCurrentForAncestorRecheck:
            @escaping @Sendable (GitCleanContinuityAuthority) -> Bool = { _ in false },
        currentObservedAncestorAmbiguityEpoch:
            @escaping @Sendable (GitCleanContinuityAuthority) -> UInt64? = { _ in nil },
        resolveAncestorAmbiguity:
            @escaping @Sendable (
                GitCleanContinuityAuthority,
                UInt64
            ) -> GitCleanContinuityAuthorityValidation = { _, _ in
                .requiresExact(.eventStreamUncertain)
            },
        markUncertain: @escaping @Sendable (UUID) -> Void,
        yieldFullGitRefresh: @escaping @Sendable (UUID, DarwinFSEventIngressSource) -> Void,
        yieldActivityObservations: @escaping @Sendable (FSEventActivityObservationBatch) -> Void,
        performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator,
        fingerprintReader: DarwinSharedExactItemFingerprintReader = .init()
    ) {
        self.streamFactory = streamFactory
        self.recordRawEvents = recordRawEvents
        self.recordAncestorAmbiguity = recordAncestorAmbiguity
        self.authorityIsCurrentForAncestorRecheck = authorityIsCurrentForAncestorRecheck
        self.currentObservedAncestorAmbiguityEpoch = currentObservedAncestorAmbiguityEpoch
        self.resolveAncestorAmbiguity = resolveAncestorAmbiguity
        self.markUncertain = markUncertain
        self.yieldFullGitRefresh = yieldFullGitRefresh
        self.yieldActivityObservations = yieldActivityObservations
        self.performanceAccumulator = performanceAccumulator
        self.fingerprintReader = fingerprintReader
    }

    package func bind(
        worktreeId: UUID,
        bindingGeneration: UInt64,
        observationIdentity: AgentStudioGit.GitStatusObservationIdentity? = nil,
        exactItemsByParent: [DarwinSharedExactItemParentKey: Set<String>],
        bindingIsCurrent: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard bindingIsCurrent() else { return false }
        let desiredExactItemsByParent = exactItemsByParent.filter { !$0.value.isEmpty }
        return bindCurrent(
            worktreeId: worktreeId,
            bindingGeneration: bindingGeneration,
            observationIdentity: observationIdentity,
            desiredExactItemsByParent: desiredExactItemsByParent,
            bindingIsCurrent: bindingIsCurrent
        )
    }

    package func stopActivityAdmission() {
        lifecycleCondition.withLock {
            hasStoppedActivityAdmission = true
        }
    }

    private func bindCurrent(
        worktreeId: UUID,
        bindingGeneration: UInt64,
        observationIdentity: AgentStudioGit.GitStatusObservationIdentity?,
        desiredExactItemsByParent: [DarwinSharedExactItemParentKey: Set<String>],
        bindingIsCurrent: @escaping @Sendable () -> Bool
    ) -> Bool {
        var startedObservers: [DarwinSharedExactItemParentKey: StartedObserver] = [:]

        while true {
            lifecycleCondition.lock()
            guard !hasShutdown, !hasStoppedActivityAdmission else {
                lifecycleCondition.unlock()
                retire(startedObservers.values.map(\.streamLifetime))
                return false
            }

            let desiredParentKeys = Set(desiredExactItemsByParent.keys)
            if !desiredParentKeys.isDisjoint(with: startingParentKeys) {
                lifecycleCondition.wait()
                lifecycleCondition.unlock()
                continue
            }

            let missingParentKeys = desiredParentKeys.filter {
                observerByParent[$0] == nil
            }
            if missingParentKeys.isEmpty {
                guard bindingIsCurrent() else {
                    lifecycleCondition.unlock()
                    retire(startedObservers.values.map(\.streamLifetime))
                    return false
                }
                let retiredStreamLifetimes = replaceBindingLocked(
                    worktreeId: worktreeId,
                    bindingGeneration: bindingGeneration,
                    observationIdentity: observationIdentity,
                    bindingIsCurrent: bindingIsCurrent,
                    desiredExactItemsByParent: desiredExactItemsByParent
                )
                lifecycleCondition.unlock()
                retire(retiredStreamLifetimes)
                return true
            }

            let generationByMissingParent = nextStreamGenerations(for: missingParentKeys)
            startingParentKeys.formUnion(missingParentKeys)
            lifecycleCondition.unlock()

            for (parentKey, streamGeneration) in generationByMissingParent {
                guard
                    let streamLifetime = streamFactory(
                        parentKey,
                        streamGeneration,
                        { [weak self] rawEvents in
                            self?.receive(
                                parentKey: parentKey,
                                streamGeneration: streamGeneration,
                                rawEvents: rawEvents
                            )
                        }
                    )
                else {
                    continue
                }
                startedObservers[parentKey] = StartedObserver(
                    generation: streamGeneration,
                    streamLifetime: streamLifetime
                )
            }

            lifecycleCondition.lock()
            startingParentKeys.subtract(missingParentKeys)
            let everyStreamStarted = Set(startedObservers.keys).isSuperset(of: missingParentKeys)
            guard !hasShutdown, everyStreamStarted, bindingIsCurrent() else {
                lifecycleCondition.broadcast()
                lifecycleCondition.unlock()
                retire(startedObservers.values.map(\.streamLifetime))
                return false
            }

            var redundantStreamLifetimes: [any DarwinSharedExactItemStreamLifetime] = []
            for (parentKey, startedObserver) in startedObservers {
                if observerByParent[parentKey] == nil {
                    observerByParent[parentKey] = ObserverState(
                        generation: startedObserver.generation,
                        streamLifetime: startedObserver.streamLifetime,
                        exactPathsByWorktreeId: [:],
                        worktreeIdsByExactPath: [:],
                        latestEventId: nil,
                        latestActivitySettledEventId: nil,
                        pendingActivityDeliveryCount: 0,
                        activeAncestorRecheckGeneration: nil,
                        unresolvedAncestorEntriesByWorktreeId: [:]
                    )
                } else {
                    redundantStreamLifetimes.append(startedObserver.streamLifetime)
                }
            }
            let retiredStreamLifetimes = replaceBindingLocked(
                worktreeId: worktreeId,
                bindingGeneration: bindingGeneration,
                observationIdentity: observationIdentity,
                bindingIsCurrent: bindingIsCurrent,
                desiredExactItemsByParent: desiredExactItemsByParent
            )
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
            retire(redundantStreamLifetimes + retiredStreamLifetimes)
            return true
        }
    }

    package func unbind(worktreeId: UUID, bindingGeneration: UInt64? = nil) {
        lifecycleCondition.lock()
        if let bindingGeneration,
            bindingValidationByWorktreeId[worktreeId]?.generation != bindingGeneration
        {
            lifecycleCondition.unlock()
            return
        }
        let retiredStreamLifetimes = replaceBindingLocked(
            worktreeId: worktreeId,
            bindingGeneration: nil,
            observationIdentity: nil,
            bindingIsCurrent: nil,
            desiredExactItemsByParent: [:]
        )
        lifecycleCondition.unlock()
        retire(retiredStreamLifetimes)
    }

    package func hasBinding(worktreeId: UUID) -> Bool {
        lifecycleCondition.withLock {
            sharedDependentWorktreeIds.contains(worktreeId)
                && bindingValidationByWorktreeId[worktreeId]?.isCurrent() == true
        }
    }

    package func retainBinding(
        worktreeId: UUID,
        bindingGeneration: UInt64
    ) -> DarwinSharedExactItemBindingRetention {
        lifecycleCondition.withLock {
            guard !hasShutdown else { return .invalid }
            guard sharedDependentWorktreeIds.contains(worktreeId) else { return .localOnly }
            guard
                let bindingValidation = bindingValidationByWorktreeId[worktreeId],
                bindingValidation.generation == bindingGeneration,
                bindingValidation.isCurrent(),
                let exactItemsByParent = exactItemsByParentByWorktreeId[worktreeId],
                !exactItemsByParent.isEmpty
            else {
                return .invalid
            }

            var streamGenerationByParent: [DarwinSharedExactItemParentKey: UInt64] = [:]
            var streamLifetimeByParent: [DarwinSharedExactItemParentKey: any DarwinSharedExactItemStreamLifetime] = [:]
            for (parentKey, exactItems) in exactItemsByParent {
                guard
                    let observer = observerByParent[parentKey],
                    observer.exactPathsByWorktreeId[worktreeId] == exactItems
                else {
                    return .invalid
                }
                streamGenerationByParent[parentKey] = observer.generation
                streamLifetimeByParent[parentKey] = observer.streamLifetime
            }
            return .shared(
                DarwinSharedExactItemBindingLease(
                    bindingGeneration: bindingGeneration,
                    exactItemsByParent: exactItemsByParent,
                    streamGenerationByParent: streamGenerationByParent,
                    streamLifetimeByParent: streamLifetimeByParent
                )
            )
        }
    }

    package func bindingIsCurrent(
        worktreeId: UUID,
        lease: DarwinSharedExactItemBindingLease
    ) -> Bool {
        lifecycleCondition.withLock {
            bindingIsCurrentLocked(worktreeId: worktreeId, lease: lease)
        }
    }

    package func installAuthorityBaseline(
        worktreeId: UUID,
        authority: GitCleanContinuityAuthority,
        lease: DarwinSharedExactItemBindingLease,
        snapshot: DarwinSharedExactItemFingerprintSnapshot
    ) -> Bool {
        lifecycleCondition.withLock {
            guard bindingIsCurrentLocked(worktreeId: worktreeId, lease: lease),
                bindingValidationByWorktreeId[worktreeId]?.observationIdentity
                    == authority.observationIdentity
            else {
                return false
            }
            return authorityBaselines.install(
                worktreeId: worktreeId,
                authority: authority,
                lease: lease,
                snapshot: snapshot
            ) != nil
        }
    }

    package func authorityBaselineIsCurrent(
        worktreeId: UUID,
        authority: GitCleanContinuityAuthority,
        lease: DarwinSharedExactItemBindingLease
    ) -> Bool {
        lifecycleCondition.withLock {
            bindingIsCurrentLocked(worktreeId: worktreeId, lease: lease)
                && !worktreeHasUnresolvedAncestorInterestLocked(worktreeId)
                && authorityBaselines.baseline(
                    worktreeId: worktreeId,
                    authority: authority,
                    lease: lease
                ) != nil
        }
    }

    package func clearAuthorityBaseline(worktreeId: UUID) {
        lifecycleCondition.withLock {
            authorityBaselines.remove(worktreeId: worktreeId)
        }
    }

    package func hasNoSharedBinding(worktreeId: UUID) -> Bool {
        lifecycleCondition.withLock {
            !hasShutdown && !sharedDependentWorktreeIds.contains(worktreeId)
        }
    }

    package func snapshot() -> DarwinSharedExactItemObservationSnapshot {
        lifecycleCondition.withLock {
            DarwinSharedExactItemObservationSnapshot(
                observerCount: observerByParent.count,
                bindingCount: sharedDependentWorktreeIds.count,
                generationByParent: observerByParent.mapValues(\.generation),
                referenceCountByParent: observerByParent.mapValues {
                    $0.exactPathsByWorktreeId.count
                },
                activeRecheckCount: observerByParent.values.count {
                    $0.activeAncestorRecheckGeneration != nil
                },
                unresolvedRegistrationCount: observerByParent.values.reduce(0) {
                    $0 + $1.unresolvedAncestorEntriesByWorktreeId.count
                }
            )
        }
    }

    package func receive(
        parentKey: DarwinSharedExactItemParentKey,
        streamGeneration: UInt64,
        rawEvents: [DarwinSharedExactItemRawEvent]
    ) {
        guard !rawEvents.isEmpty else { return }
        performanceAccumulator.recordSharedRawCallback(eventCount: rawEvents.count)

        lifecycleCondition.lock()
        guard !hasShutdown, !hasStoppedActivityAdmission,
            var observer = observerByParent[parentKey],
            observer.generation == streamGeneration
        else {
            lifecycleCondition.unlock()
            return
        }

        var ancestorItemsByWorktreeId: [UUID: Set<String>] = [:]
        var ancestorEventIdByWorktreeId: [UUID: FSEventStreamEventId] = [:]
        let dependentWorktreeIds = Set(
            observer.exactPathsByWorktreeId.keys.filter {
                bindingValidationByWorktreeId[$0]?.isCurrent() == true
            })

        let classification = classifyReceiveEvents(
            rawEvents,
            dependentWorktreeIds: dependentWorktreeIds,
            observer: &observer,
            ancestorItemsByWorktreeId: &ancestorItemsByWorktreeId,
            ancestorEventIdByWorktreeId: &ancestorEventIdByWorktreeId
        )

        for worktreeId in classification.uncertainWorktreeIds {
            ancestorItemsByWorktreeId.removeValue(forKey: worktreeId)
            observer.unresolvedAncestorEntriesByWorktreeId.removeValue(forKey: worktreeId)
        }
        for worktreeId in classification.exactSubscriberWorktreeIds.subtracting(classification.uncertainWorktreeIds) {
            ancestorItemsByWorktreeId.removeValue(forKey: worktreeId)
            let exactHitPaths = Set(
                classification.mutationEventsByWorktreeId[worktreeId, default: []].map {
                    DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath($0.path)
                }
            )
            guard
                var unresolvedEntry =
                    observer.unresolvedAncestorEntriesByWorktreeId[worktreeId]
            else { continue }
            unresolvedEntry.canonicalItemPaths.subtract(exactHitPaths)
            if unresolvedEntry.canonicalItemPaths.isEmpty {
                observer.unresolvedAncestorEntriesByWorktreeId.removeValue(forKey: worktreeId)
            } else {
                observer.unresolvedAncestorEntriesByWorktreeId[worktreeId] = unresolvedEntry
            }
        }
        mergeAncestorAmbiguityLocked(
            ancestorItemsByWorktreeId,
            latestEventIdByWorktreeId: ancestorEventIdByWorktreeId,
            into: &observer
        )

        let fullGitRefreshWorktreeIds = admitFullRefreshLocked(
            classification.exactSubscriberWorktreeIds.union(classification.uncertainWorktreeIds)
        )
        let activityCoverageLostWorktreeIds = classification.uncertainWorktreeIds.union(
            classification.exactHitWithPendingAncestorWorktreeIds.subtracting(
                classification.activityQualifyingWorktreeIds)
        ).union(classification.activityOwnEventWorktreeIds)
        var retiredStreamLifetime: (any DarwinSharedExactItemStreamLifetime)?
        var ancestorRecheckToStart: DarwinSharedExactItemAncestorRecheckSnapshot?
        if classification.shouldRetireObserver {
            retiredStreamLifetime = retireObserverLocked(parentKey: parentKey)
        } else {
            observer.pendingActivityDeliveryCount += 1
            observerByParent[parentKey] = observer
            ancestorRecheckToStart = beginNextAncestorRecheckLocked(parentKey: parentKey)
        }
        lifecycleCondition.unlock()
        emitReceiveEffects(
            DarwinSharedExactItemReceiveEffects(
                parentKey: parentKey,
                streamGeneration: streamGeneration,
                activityObservationBatch: Self.makeActivityObservationBatch(
                    parentKey: parentKey,
                    streamGeneration: streamGeneration,
                    rawEvents: rawEvents,
                    participantWorktreeIds: dependentWorktreeIds,
                    qualifyingWorktreeIds: classification.activityQualifyingWorktreeIds,
                    coverageLostWorktreeIds: activityCoverageLostWorktreeIds
                ),
                mutationEventsByWorktreeId: classification.mutationEventsByWorktreeId,
                uncertainWorktreeIds: classification.uncertainWorktreeIds,
                exactSubscriberWorktreeIds: classification.exactSubscriberWorktreeIds,
                fullGitRefreshWorktreeIds: fullGitRefreshWorktreeIds,
                retiredStreamLifetime: retiredStreamLifetime,
                ancestorRecheckToStart: ancestorRecheckToStart
            )
        )
    }

    private func nextStreamGenerations(
        for parentKeys: Set<DarwinSharedExactItemParentKey>
    ) -> [DarwinSharedExactItemParentKey: UInt64] {
        Dictionary(
            uniqueKeysWithValues: parentKeys.map { parentKey in
                nextStreamGeneration &+= 1
                return (parentKey, nextStreamGeneration)
            })
    }

    private func classifyReceiveEvents(
        _ rawEvents: [DarwinSharedExactItemRawEvent],
        dependentWorktreeIds: Set<UUID>,
        observer: inout ObserverState,
        ancestorItemsByWorktreeId: inout [UUID: Set<String>],
        ancestorEventIdByWorktreeId: inout [UUID: FSEventStreamEventId]
    ) -> ReceiveClassification {
        var result = ReceiveClassification()
        for rawEvent in rawEvents {
            let normalizedPath = DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath(rawEvent.path)
            let cursorRegressed = observer.latestEventId.map { rawEvent.eventId < $0 } ?? false
            observer.latestEventId = rawEvent.eventId
            let exactSubscribers = (observer.worktreeIdsByExactPath[normalizedPath] ?? []).filter {
                bindingValidationByWorktreeId[$0]?.isCurrent() == true
            }
            for worktreeId in exactSubscribers {
                result.mutationEventsByWorktreeId[worktreeId, default: []].append(
                    DarwinFSEventClassifiedRawEvent(
                        eventId: rawEvent.eventId, flags: rawEvent.flags, hasRelevantMutation: true, path: rawEvent.path
                    )
                )
            }
            result.exactSubscriberWorktreeIds.formUnion(exactSubscribers)
            result.exactHitWithPendingAncestorWorktreeIds.formUnion(
                exactSubscribers.filter {
                    observer.unresolvedAncestorEntriesByWorktreeId[$0] != nil
                })
            if RepositoryLocalActivityPathClassifier.qualifiesGitMetadataPath(normalizedPath) {
                if rawEvent.flags
                    & FSEventStreamEventFlags(kFSEventStreamEventFlagOwnEvent) != 0
                {
                    result.activityOwnEventWorktreeIds.formUnion(exactSubscribers)
                } else {
                    result.activityQualifyingWorktreeIds.formUnion(exactSubscribers)
                }
            }
            if rawEvent.flags & Self.uncertaintyFlags != 0 || cursorRegressed {
                result.uncertainWorktreeIds.formUnion(dependentWorktreeIds)
            } else {
                for (exactPath, worktreeIds) in observer.worktreeIdsByExactPath
                where exactPath.hasPrefix(normalizedPath + "/") {
                    for worktreeId in worktreeIds where bindingValidationByWorktreeId[worktreeId]?.isCurrent() == true {
                        ancestorItemsByWorktreeId[worktreeId, default: []].insert(exactPath)
                        ancestorEventIdByWorktreeId[worktreeId] = max(
                            ancestorEventIdByWorktreeId[worktreeId] ?? rawEvent.eventId, rawEvent.eventId)
                    }
                }
            }
            result.shouldRetireObserver = result.shouldRetireObserver || Self.isRootChange(rawEvent)
        }
        return result
    }

    private func mergeAncestorAmbiguityLocked(
        _ ancestorItemsByWorktreeId: [UUID: Set<String>],
        latestEventIdByWorktreeId: [UUID: FSEventStreamEventId],
        into observer: inout ObserverState
    ) {
        for worktreeId in ancestorItemsByWorktreeId.keys.sorted(by: Self.sortWorktreeIds) {
            guard let canonicalItemPaths = ancestorItemsByWorktreeId[worktreeId],
                let latestEventId = latestEventIdByWorktreeId[worktreeId],
                let observedEpoch = recordAncestorAmbiguity(worktreeId)
            else {
                continue
            }
            if var unresolvedEntry = observer.unresolvedAncestorEntriesByWorktreeId[worktreeId] {
                unresolvedEntry.merge(
                    observedEpoch: observedEpoch,
                    latestEventId: latestEventId,
                    canonicalItemPaths: canonicalItemPaths
                )
                observer.unresolvedAncestorEntriesByWorktreeId[worktreeId] = unresolvedEntry
            } else {
                observer.unresolvedAncestorEntriesByWorktreeId[worktreeId] =
                    DarwinSharedExactItemAncestorUnresolvedEntry(
                        observedEpoch: observedEpoch,
                        latestEventId: latestEventId,
                        canonicalItemPaths: canonicalItemPaths
                    )
            }
        }
    }

    package func shutdown() {
        lifecycleCondition.lock()
        guard !hasShutdown else {
            lifecycleCondition.unlock()
            return
        }
        hasShutdown = true
        let streamLifetimes = observerByParent.values.map(\.streamLifetime)
        observerByParent.removeAll(keepingCapacity: false)
        exactItemsByParentByWorktreeId.removeAll(keepingCapacity: false)
        bindingValidationByWorktreeId.removeAll(keepingCapacity: false)
        sharedDependentWorktreeIds.removeAll(keepingCapacity: false)
        fullRefreshDeliveryOutstandingWorktreeIds.removeAll(keepingCapacity: false)
        authorityBaselines.removeAll()
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()
        retire(streamLifetimes)
    }

    private func replaceBindingLocked(
        worktreeId: UUID,
        bindingGeneration: UInt64?,
        observationIdentity: AgentStudioGit.GitStatusObservationIdentity?,
        bindingIsCurrent: (@Sendable () -> Bool)?,
        desiredExactItemsByParent: [DarwinSharedExactItemParentKey: Set<String>]
    ) -> [any DarwinSharedExactItemStreamLifetime] {
        activityTopologyRevision &+= 1
        fullRefreshDeliveryOutstandingWorktreeIds.remove(worktreeId)
        authorityBaselines.remove(worktreeId: worktreeId)
        let previousExactItemsByParent = exactItemsByParentByWorktreeId[worktreeId] ?? [:]
        let allParentKeys = Set(previousExactItemsByParent.keys)
            .union(desiredExactItemsByParent.keys)
        var retiredStreamLifetimes: [any DarwinSharedExactItemStreamLifetime] = []

        for parentKey in allParentKeys {
            guard var observer = observerByParent[parentKey] else { continue }
            observer.unresolvedAncestorEntriesByWorktreeId.removeValue(forKey: worktreeId)
            let previousExactPaths = previousExactItemsByParent[parentKey] ?? []
            let desiredExactPaths = desiredExactItemsByParent[parentKey] ?? []

            for exactPath in previousExactPaths.subtracting(desiredExactPaths) {
                observer.worktreeIdsByExactPath[exactPath]?.remove(worktreeId)
                if observer.worktreeIdsByExactPath[exactPath]?.isEmpty == true {
                    observer.worktreeIdsByExactPath.removeValue(forKey: exactPath)
                }
            }
            for exactPath in desiredExactPaths {
                observer.worktreeIdsByExactPath[exactPath, default: []].insert(worktreeId)
            }
            if desiredExactPaths.isEmpty {
                observer.exactPathsByWorktreeId.removeValue(forKey: worktreeId)
            } else {
                observer.exactPathsByWorktreeId[worktreeId] = desiredExactPaths
            }

            if observer.exactPathsByWorktreeId.isEmpty {
                observerByParent.removeValue(forKey: parentKey)
                retiredStreamLifetimes.append(observer.streamLifetime)
            } else {
                observerByParent[parentKey] = observer
            }
        }

        if desiredExactItemsByParent.isEmpty {
            exactItemsByParentByWorktreeId.removeValue(forKey: worktreeId)
            bindingValidationByWorktreeId.removeValue(forKey: worktreeId)
            sharedDependentWorktreeIds.remove(worktreeId)
        } else {
            guard let bindingGeneration, let bindingIsCurrent else {
                return retiredStreamLifetimes
            }
            exactItemsByParentByWorktreeId[worktreeId] = desiredExactItemsByParent
            bindingValidationByWorktreeId[worktreeId] = BindingValidation(
                generation: bindingGeneration,
                observationIdentity: observationIdentity,
                isCurrent: bindingIsCurrent
            )
            sharedDependentWorktreeIds.insert(worktreeId)
        }
        return retiredStreamLifetimes
    }

    private func retireObserverLocked(
        parentKey: DarwinSharedExactItemParentKey
    ) -> (any DarwinSharedExactItemStreamLifetime)? {
        guard let observer = observerByParent.removeValue(forKey: parentKey) else { return nil }
        activityTopologyRevision &+= 1
        for worktreeId in observer.exactPathsByWorktreeId.keys {
            authorityBaselines.remove(worktreeId: worktreeId)
            exactItemsByParentByWorktreeId[worktreeId]?.removeValue(forKey: parentKey)
            if exactItemsByParentByWorktreeId[worktreeId]?.isEmpty == true {
                exactItemsByParentByWorktreeId.removeValue(forKey: worktreeId)
            }
        }
        return observer.streamLifetime
    }

    private func bindingIsCurrentLocked(
        worktreeId: UUID,
        lease: DarwinSharedExactItemBindingLease
    ) -> Bool {
        guard !hasShutdown,
            sharedDependentWorktreeIds.contains(worktreeId),
            let bindingValidation = bindingValidationByWorktreeId[worktreeId],
            bindingValidation.generation == lease.bindingGeneration,
            bindingValidation.isCurrent(),
            exactItemsByParentByWorktreeId[worktreeId] == lease.exactItemsByParent
        else {
            return false
        }
        return lease.streamGenerationByParent.allSatisfy { parentKey, generation in
            observerByParent[parentKey]?.generation == generation
                && observerByParent[parentKey]?.exactPathsByWorktreeId[worktreeId]
                    == lease.exactItemsByParent[parentKey]
        }
    }

    private func retire(_ streamLifetimes: [any DarwinSharedExactItemStreamLifetime]) {
        for streamLifetime in streamLifetimes {
            streamLifetime.retire()
        }
    }

}

package enum DarwinFSEventPathNormalizer {
    package static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        guard containsNonCanonicalPathComponent(path) else { return path }

        var normalizedComponents: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !normalizedComponents.isEmpty {
                    normalizedComponents.removeLast()
                }
            default:
                normalizedComponents.append(component)
            }
        }
        guard !normalizedComponents.isEmpty else { return "/" }
        return "/" + normalizedComponents.joined(separator: "/")
    }

    private static func containsNonCanonicalPathComponent(_ path: String) -> Bool {
        if let result = path.utf8.withContiguousStorageIfAvailable(scanNonCanonicalPathComponents) {
            return result
        }
        return Array(path.utf8).withUnsafeBufferPointer(scanNonCanonicalPathComponents)
    }

    private static func scanNonCanonicalPathComponents(
        _ bytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        let separator = UInt8(ascii: "/")
        let dot = UInt8(ascii: ".")
        var hasConsumedLeadingSeparator = false
        var componentLength = 0
        var componentContainsOnlyDots = true
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == separator {
                if !hasConsumedLeadingSeparator {
                    hasConsumedLeadingSeparator = true
                    continue
                }
                if componentLength == 0
                    || componentContainsOnlyDots && componentLength <= 2
                {
                    return true
                }
                componentLength = 0
                componentContainsOnlyDots = true
                continue
            }

            componentLength += 1
            if byte != dot {
                componentContainsOnlyDots = false
            }
        }

        return componentContainsOnlyDots && (componentLength == 1 || componentLength == 2)
    }
}
