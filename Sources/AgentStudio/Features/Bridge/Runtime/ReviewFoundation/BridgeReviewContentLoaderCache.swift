import AgentStudioInfrastructure
import Foundation

/// Loads and caches immutable Review content selected by native publication authority.
///
/// This actor deliberately owns no package, generation, descriptor, or handle lookup
/// authority. Every load begins with the exact handle carried by a publication lease.
actor BridgeReviewContentLoaderCache {
    private struct ContentKey: Hashable {
        let handleId: String
        let reviewGeneration: BridgeReviewGeneration
        let itemId: String
        let role: BridgeContentHandle.Role
        let endpointId: String
        let contentHash: String
        let contentHashAlgorithm: String
        let isBinary: Bool
    }

    private struct ValidatedContent {
        let result: BridgeContentLoadResult
    }

    private struct InFlightLoad {
        let id: UUID
        let providerCompletion: BridgeReviewProviderLoadCompletion
        let sharedLoad: BridgeContentSharedLoad
    }

    private let provider: (any BridgeReviewSourceProvider)?
    private let contentCacheMaxBytes: Int
    private let contentMaxBytesPerItem: Int
    private var contentByKey: [ContentKey: ValidatedContent] = [:]
    private var inFlightLoadByKey: [ContentKey: InFlightLoad] = [:]
    private var cachedByteCountByKey: [ContentKey: Int] = [:]
    private var lastAccessCounterByKey: [ContentKey: Int] = [:]
    private var accessCounter = 0
    private var totalCachedBytes = 0
    private var isClosed = false

    init(
        provider: (any BridgeReviewSourceProvider)? = nil,
        contentCacheMaxBytes: Int = AppPolicies.Bridge.contentCacheMaxBytes,
        contentMaxBytesPerItem: Int = AppPolicies.Bridge.contentMaxBytesPerItem
    ) {
        self.provider = provider
        self.contentCacheMaxBytes = contentCacheMaxBytes
        self.contentMaxBytesPerItem = contentMaxBytesPerItem
    }

    var diagnosticSnapshot: BridgeReviewContentLoaderCacheDiagnosticSnapshot {
        removeCompletedInFlightLoads()
        return BridgeReviewContentLoaderCacheDiagnosticSnapshot(
            cachedContentCount: contentByKey.count,
            inFlightLoadCount: inFlightLoadByKey.count,
            totalCachedBytes: totalCachedBytes,
            isClosed: isClosed
        )
    }

    func load(
        handle: BridgeContentHandle,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeContentLoadResult {
        do {
            return try await loadObserved(
                handle: handle,
                productAdmission: productAdmission
            ).result
        } catch let failure as BridgeContentLoadObservedFailure {
            throw failure.underlyingError
        }
    }

    func loadObserved(
        handle: BridgeContentHandle,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeContentLoadObservedResult {
        try Task.checkCancellation()
        try validateLoadAdmission(handle: handle, productAdmission: productAdmission)
        let key = contentKey(for: handle)

        if let cachedContent = contentByKey[key] {
            do {
                let normalizedResult = try normalizeValidatedCachedResult(
                    cachedContent,
                    requestedHandle: handle
                )
                try validatePostAwaitAdmission(handle: handle, productAdmission: productAdmission)
                touchCachedContent(for: key)
                return observedResult(normalizedResult, cacheResult: .cacheHit)
            } catch {
                throw observedFailure(
                    error,
                    handle: handle,
                    cacheResult: .cacheHit
                )
            }
        }

        guard let provider else {
            throw observedFailure(
                BridgeProviderFailure.providerUnavailable,
                handle: handle,
                cacheResult: .rejected
            )
        }

        while true {
            let inFlightLoad: InFlightLoad
            let cacheResult: BridgeContentLoadObservation.CacheResult
            if let existingLoad = reusableInFlightLoad(for: key) {
                inFlightLoad = existingLoad
                cacheResult = .inFlightCoalesced
            } else {
                let providerCompletion = BridgeReviewProviderLoadCompletion()
                let task = Task {
                    defer { providerCompletion.finish() }
                    return try await provider.loadContent(
                        BridgeContentLoadRequest(
                            handle: handle,
                            requestedGeneration: handle.reviewGeneration
                        )
                    )
                }
                let newLoad = InFlightLoad(
                    id: UUIDv7.generate(),
                    providerCompletion: providerCompletion,
                    sharedLoad: BridgeContentSharedLoad(task: task)
                )
                inFlightLoadByKey[key] = newLoad
                inFlightLoad = newLoad
                cacheResult = .providerLoad
            }

            do {
                let providerResult = try await inFlightLoad.sharedLoad.value()
                removeInFlightLoadIfProviderCompleted(inFlightLoad, for: key)
                try Task.checkCancellation()
                try validatePostAwaitAdmission(handle: handle, productAdmission: productAdmission)
                let normalizedResult = try normalizeProviderResult(
                    providerResult,
                    requestedHandle: handle
                )
                cache(normalizedResult, for: key)
                return observedResult(normalizedResult, cacheResult: cacheResult)
            } catch is BridgeContentSharedLoadAbandoned {
                // Registration rejected this retired load. Its physical read
                // must finish before a successor can start another one.
                await inFlightLoad.providerCompletion.wait()
                removeInFlightLoad(inFlightLoad, for: key)
                try Task.checkCancellation()
                try validateLoadAdmission(handle: handle, productAdmission: productAdmission)
            } catch let failure as BridgeContentLoadObservedFailure {
                removeInFlightLoadIfProviderCompleted(inFlightLoad, for: key)
                throw failure
            } catch {
                removeInFlightLoadIfProviderCompleted(inFlightLoad, for: key)
                throw observedFailure(
                    error,
                    handle: handle,
                    cacheResult: cacheResult
                )
            }
        }
    }

    func cachedResultsIfAllResident(
        handles: [BridgeContentHandle],
        productAdmission: BridgeProductAdmissionContext
    ) -> [String: BridgeContentLoadResult]? {
        guard !isClosed,
            productAdmission.withValidAdmission({ true }) == true
        else { return nil }
        var resultByHandleID: [String: BridgeContentLoadResult] = [:]
        var keys: [ContentKey] = []
        resultByHandleID.reserveCapacity(handles.count)
        keys.reserveCapacity(handles.count)
        for handle in handles {
            do {
                try validateHandleCanLoad(handle)
                let key = contentKey(for: handle)
                guard let cachedContent = contentByKey[key] else { return nil }
                let result = try normalizeValidatedCachedResult(
                    cachedContent,
                    requestedHandle: handle
                )
                guard resultByHandleID.updateValue(result, forKey: handle.handleId) == nil else {
                    return nil
                }
                keys.append(key)
            } catch {
                return nil
            }
        }
        for key in keys {
            touchCachedContent(for: key)
        }
        return resultByHandleID
    }

    /// Synchronously rejects new work, then waits for every started provider call
    /// to return before reporting zero residue.
    func closeAndDrain() async {
        isClosed = true
        clearCachedContent()
        let loads = Array(inFlightLoadByKey.values)
        for load in loads {
            load.sharedLoad.cancel()
        }
        for load in loads {
            await load.providerCompletion.wait()
            removeInFlightLoad(load)
        }
    }

    private func validateLoadAdmission(
        handle: BridgeContentHandle,
        productAdmission: BridgeProductAdmissionContext
    ) throws {
        guard !isClosed else {
            throw observedFailure(
                BridgeReviewContentLoaderCacheError.closed,
                handle: handle,
                cacheResult: .rejected
            )
        }
        guard (productAdmission.withValidAdmission { true }) == true else {
            throw observedFailure(
                BridgeReviewContentLoaderCacheError.productAdmissionRejected,
                handle: handle,
                cacheResult: .rejected
            )
        }
        do {
            try validateHandleCanLoad(handle)
        } catch {
            throw observedFailure(
                error,
                handle: handle,
                cacheResult: .rejected
            )
        }
    }

    private func validatePostAwaitAdmission(
        handle: BridgeContentHandle,
        productAdmission: BridgeProductAdmissionContext
    ) throws {
        guard !isClosed else {
            throw BridgeReviewContentLoaderCacheError.closed
        }
        guard (productAdmission.withValidAdmission { true }) == true else {
            throw BridgeReviewContentLoaderCacheError.productAdmissionRejected
        }
        try validateHandleCanLoad(handle)
    }

    private func normalizeProviderResult(
        _ result: BridgeContentLoadResult,
        requestedHandle: BridgeContentHandle
    ) throws -> BridgeContentLoadResult {
        try validateResult(result, for: requestedHandle)
        return normalizedResult(result, requestedHandle: requestedHandle)
    }

    private func normalizeValidatedCachedResult(
        _ validatedContent: ValidatedContent,
        requestedHandle: BridgeContentHandle
    ) throws -> BridgeContentLoadResult {
        let result = validatedContent.result
        try validateResultEnvelope(result, for: requestedHandle)
        try validateResultGeneration(result, for: requestedHandle)
        return normalizedResult(result, requestedHandle: requestedHandle)
    }

    private func normalizedResult(
        _ result: BridgeContentLoadResult,
        requestedHandle: BridgeContentHandle
    ) -> BridgeContentLoadResult {
        BridgeContentLoadResult(
            handle: requestedHandle,
            data: result.data,
            mimeType: requestedHandle.mimeType,
            contentHash: requestedHandle.contentHash,
            contentHashAlgorithm: requestedHandle.contentHashAlgorithm
        )
    }

    private func validateResult(
        _ result: BridgeContentLoadResult,
        for handle: BridgeContentHandle
    ) throws {
        try validateResultEnvelope(result, for: handle)
        let computedHash = try bridgeComputedContentHash(
            for: result.data,
            algorithm: handle.contentHashAlgorithm
        )
        guard computedHash == handle.contentHash else {
            throw BridgeProviderFailure.contentHashMismatch(
                handleId: handle.handleId,
                expectedHash: handle.contentHash,
                actualHash: computedHash
            )
        }
        try validateResultGeneration(result, for: handle)
    }

    private func validateResultEnvelope(
        _ result: BridgeContentLoadResult,
        for handle: BridgeContentHandle
    ) throws {
        try validateHandleCanLoad(handle)
        guard result.handle.handleId == handle.handleId,
            result.handle.itemId == handle.itemId,
            result.handle.role == handle.role,
            result.handle.endpointId == handle.endpointId
        else {
            throw BridgeProviderFailure.providerFailed(
                message: "Content result identity mismatch for \(handle.handleId)"
            )
        }
        guard result.data.count <= contentMaxBytesPerItem else {
            throw BridgeProviderFailure.oversizedContent(
                handleId: handle.handleId,
                sizeBytes: result.data.count
            )
        }
        guard !handle.sizeBytesIsExact || result.data.count <= handle.sizeBytes else {
            throw BridgeProviderFailure.oversizedContent(
                handleId: handle.handleId,
                sizeBytes: result.data.count
            )
        }
        guard result.contentHashAlgorithm == handle.contentHashAlgorithm,
            result.contentHash == handle.contentHash
        else {
            throw BridgeProviderFailure.contentHashMismatch(
                handleId: handle.handleId,
                expectedHash: handle.contentHash,
                actualHash: result.contentHash
            )
        }
    }

    private func validateResultGeneration(
        _ result: BridgeContentLoadResult,
        for handle: BridgeContentHandle
    ) throws {
        guard result.handle.reviewGeneration == handle.reviewGeneration else {
            throw BridgeProviderFailure.staleReviewGeneration(
                storedGeneration: handle.reviewGeneration,
                requestedGeneration: result.handle.reviewGeneration
            )
        }
    }

    private func validateHandleCanLoad(_ handle: BridgeContentHandle) throws {
        if handle.isBinary {
            throw BridgeProviderFailure.binaryContent(handleId: handle.handleId)
        }
    }

    private func observedResult(
        _ result: BridgeContentLoadResult,
        cacheResult: BridgeContentLoadObservation.CacheResult
    ) -> BridgeContentLoadObservedResult {
        BridgeContentLoadObservedResult(
            result: result,
            observation: BridgeContentLoadObservationFactory.make(
                cacheResult: cacheResult,
                handle: result.handle,
                requestedGeneration: result.handle.reviewGeneration,
                data: result.data,
                error: nil
            )
        )
    }

    private func observedFailure(
        _ error: any Error,
        handle: BridgeContentHandle,
        cacheResult: BridgeContentLoadObservation.CacheResult
    ) -> BridgeContentLoadObservedFailure {
        BridgeContentLoadObservedFailure(
            underlyingError: error,
            observation: BridgeContentLoadObservationFactory.make(
                cacheResult: cacheResult,
                handle: handle,
                requestedGeneration: handle.reviewGeneration,
                data: nil,
                error: error
            )
        )
    }

    private func cache(_ result: BridgeContentLoadResult, for key: ContentKey) {
        let previousByteCount = cachedByteCountByKey[key] ?? 0
        let byteCount = result.data.count
        contentByKey[key] = ValidatedContent(result: result)
        cachedByteCountByKey[key] = byteCount
        totalCachedBytes += byteCount - previousByteCount
        touchCachedContent(for: key)
        evictLeastRecentlyUsedContent(preserving: key)
    }

    private func touchCachedContent(for key: ContentKey) {
        accessCounter += 1
        lastAccessCounterByKey[key] = accessCounter
    }

    private func evictLeastRecentlyUsedContent(preserving preservedKey: ContentKey) {
        while totalCachedBytes > contentCacheMaxBytes, contentByKey.count > 1 {
            let evictableKey =
                lastAccessCounterByKey
                .filter { $0.key != preservedKey && contentByKey[$0.key] != nil }
                .min { left, right in left.value < right.value }?
                .key
            guard let evictableKey else { return }
            removeCachedContent(for: evictableKey)
        }
    }

    private func removeCachedContent(for key: ContentKey) {
        guard contentByKey.removeValue(forKey: key) != nil else { return }
        totalCachedBytes -= cachedByteCountByKey.removeValue(forKey: key) ?? 0
        lastAccessCounterByKey.removeValue(forKey: key)
    }

    private func clearCachedContent() {
        contentByKey.removeAll(keepingCapacity: false)
        cachedByteCountByKey.removeAll(keepingCapacity: false)
        lastAccessCounterByKey.removeAll(keepingCapacity: false)
        totalCachedBytes = 0
    }

    private func reusableInFlightLoad(for key: ContentKey) -> InFlightLoad? {
        guard let load = inFlightLoadByKey[key] else { return nil }
        if load.sharedLoad.isTerminal, load.providerCompletion.isComplete {
            removeInFlightLoadIfProviderCompleted(load, for: key)
            return nil
        }
        return load
    }

    private func removeCompletedInFlightLoads() {
        inFlightLoadByKey = inFlightLoadByKey.filter { _, load in
            !load.providerCompletion.isComplete
        }
    }

    private func removeInFlightLoadIfProviderCompleted(
        _ load: InFlightLoad,
        for key: ContentKey
    ) {
        guard load.providerCompletion.isComplete else { return }
        removeInFlightLoad(load, for: key)
    }

    private func removeInFlightLoad(_ load: InFlightLoad, for key: ContentKey) {
        guard inFlightLoadByKey[key]?.id == load.id else { return }
        inFlightLoadByKey.removeValue(forKey: key)
    }

    private func removeInFlightLoad(_ load: InFlightLoad) {
        guard let key = inFlightLoadByKey.first(where: { $0.value.id == load.id })?.key else {
            return
        }
        inFlightLoadByKey.removeValue(forKey: key)
    }

    private func contentKey(for handle: BridgeContentHandle) -> ContentKey {
        ContentKey(
            handleId: handle.handleId,
            reviewGeneration: handle.reviewGeneration,
            itemId: handle.itemId,
            role: handle.role,
            endpointId: handle.endpointId,
            contentHash: handle.contentHash,
            contentHashAlgorithm: handle.contentHashAlgorithm,
            isBinary: handle.isBinary
        )
    }
}

private final class BridgeReviewProviderLoadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isComplete: Bool {
        lock.withLock { completed }
    }

    func finish() {
        let continuations = lock.withLock {
            guard !completed else { return [CheckedContinuation<Void, Never>]() }
            completed = true
            let continuations = waiters
            waiters.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !completed else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}
