import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Review content loader cache")
struct BridgeReviewContentLoaderCacheTests {
    @Test("loader cache owns loading and caching, never publication authority")
    func loaderCacheOwnsOnlyLoadingAndCaching() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(
                path:
                    "Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewContentLoaderCache.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("actor BridgeReviewContentLoaderCache"))
        #expect(!source.contains("activeReviewGeneration"))
        #expect(!source.contains("activeAuthorityRevision"))
        #expect(!source.contains("handleByKey"))
        #expect(!source.contains("keyByHandleId"))
        #expect(!source.contains("func activate("))
        #expect(!source.contains("func deactivate("))
        #expect(!source.contains("func register("))
        #expect(!source.contains("func metadata("))
    }

    @Test("first handle load validates provider bytes and the second hits cache")
    func firstLoadValidatesProviderAndSecondLoadHitsCache() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "cached")
        let provider = makeLoaderCacheProvider(results: [makeContentResult(handle: handle, data: "cached")])
        let cache = BridgeReviewContentLoaderCache(provider: provider)

        let first = try await cache.loadObserved(
            handle: handle,
            productAdmission: admission.context
        )
        let second = try await cache.loadObserved(
            handle: handle,
            productAdmission: admission.context
        )

        #expect(first.result.data == Data("cached".utf8))
        #expect(first.observation.cacheResult == .providerLoad)
        #expect(second.observation.cacheResult == .cacheHit)
        #expect(await provider.recordedContentRequestsCount() == 1)
    }

    @Test("concurrent callers coalesce one immutable handle load")
    func concurrentCallersCoalesceOneLoad() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "coalesced")
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: handle, data: "coalesced")],
            gate: gate
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider)

        async let first = cache.loadObserved(handle: handle, productAdmission: admission.context)
        try await gate.firstArrival()
        async let second = cache.loadObserved(handle: handle, productAdmission: admission.context)
        async let third = cache.loadObserved(handle: handle, productAdmission: admission.context)
        await Task.yield()
        gate.release()
        let results = try await [first, second, third]

        #expect(results.map(\.result.data) == Array(repeating: Data("coalesced".utf8), count: 3))
        #expect(results.map(\.observation.cacheResult).contains(.providerLoad))
        #expect(results.map(\.observation.cacheResult).filter { $0 == .inFlightCoalesced }.count == 2)
        #expect(await provider.recordedContentRequestsCount() == 1)
    }

    @Test("cache rejects a provider result with mismatched handle identity")
    func rejectsMismatchedProviderIdentity() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "identity")
        let mismatchedHandle = BridgeContentHandle(
            handleId: handle.handleId,
            itemId: "different-item",
            role: handle.role,
            endpointId: handle.endpointId,
            reviewGeneration: handle.reviewGeneration,
            contentHash: handle.contentHash,
            contentHashAlgorithm: handle.contentHashAlgorithm,
            cacheKey: handle.cacheKey,
            mimeType: handle.mimeType,
            language: handle.language,
            sizeBytes: handle.sizeBytes,
            sizeBytesIsExact: handle.sizeBytesIsExact,
            isBinary: handle.isBinary
        )
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: mismatchedHandle, data: "identity")]
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider)

        await #expect(throws: BridgeProviderFailure.self) {
            _ = try await cache.load(handle: handle, productAdmission: admission.context)
        }
    }

    @Test("cache rejects content whose computed hash differs from the issued handle")
    func rejectsComputedHashMismatch() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "expected")
        let forgedResult = BridgeContentLoadResult(
            handle: handle,
            data: Data("different".utf8),
            mimeType: handle.mimeType,
            contentHash: handle.contentHash,
            contentHashAlgorithm: handle.contentHashAlgorithm
        )
        let cache = BridgeReviewContentLoaderCache(
            provider: makeLoaderCacheProvider(results: [forgedResult])
        )

        await #expect(throws: BridgeProviderFailure.self) {
            _ = try await cache.load(handle: handle, productAdmission: admission.context)
        }
    }

    @Test("cache rejects binary and oversized handles before publication")
    func rejectsBinaryAndOversizedContent() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let binaryHandle = makeBridgeContentHandle(
            itemId: "binary-item",
            role: .head,
            reviewGeneration: 7,
            contentHash: bridgeSHA256ContentHash("binary"),
            sizeBytes: 6,
            isBinary: true
        )
        let oversizedHandle = makeLoaderCacheHandle(content: "1234567", itemId: "oversized-item")
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: oversizedHandle, data: "1234567")]
        )
        let cache = BridgeReviewContentLoaderCache(
            provider: provider,
            contentMaxBytesPerItem: 6
        )

        await #expect(throws: BridgeProviderFailure.self) {
            _ = try await cache.load(handle: binaryHandle, productAdmission: admission.context)
        }
        await #expect(throws: BridgeProviderFailure.self) {
            _ = try await cache.load(handle: oversizedHandle, productAdmission: admission.context)
        }
    }

    @Test("closing admission while provider is suspended prevents cache publication")
    func admissionClosePreventsLateCachePublication() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "late")
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: handle, data: "late")],
            gate: gate
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider)
        let load = Task {
            try await cache.load(handle: handle, productAdmission: admission.context)
        }
        try await gate.firstArrival()

        admission.close()
        gate.release()

        await #expect(throws: BridgeReviewContentLoaderCacheError.self) {
            _ = try await load.value
        }
        #expect((await cache.diagnosticSnapshot).cachedContentCount == 0)
    }

    @Test("close and drain rejects future work and reports zero residue")
    func closeAndDrainRejectsFutureWorkAndReportsZeroResidue() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "draining")
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: handle, data: "draining")],
            gate: gate
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider)
        let load = Task {
            try await cache.load(handle: handle, productAdmission: admission.context)
        }
        try await gate.firstArrival()
        let close = Task { await cache.closeAndDrain() }
        gate.release()

        _ = try? await load.value
        await close.value
        let snapshot = await cache.diagnosticSnapshot

        #expect(snapshot.isClosed)
        #expect(snapshot.cachedContentCount == 0)
        #expect(snapshot.inFlightLoadCount == 0)
        #expect(snapshot.totalCachedBytes == 0)
        await #expect(throws: BridgeReviewContentLoaderCacheError.self) {
            _ = try await cache.load(handle: handle, productAdmission: admission.context)
        }
    }

    @Test("a successor waits for an abandoned provider then loads fresh content without overlapping reads")
    func successorWaitsForAbandonedProviderAndLoadsFreshContent() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "successor")
        let gate = HeldStep<Void>("abandoned provider", cancellation: .holdThroughCancellation)
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: handle, data: "successor")],
            gate: gate,
            checksCancellationAfterGate: true
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider)
        try await abandonInitialLoaderCacheLoad(cache, handle: handle, admission: admission.context, gate: gate)
        let successor = try await startLoaderCacheSuccessor(
            cache, handle: handle, admission: admission.context, gate: gate
        )

        gate.release()
        let successorOutcome = await successor.value
        await cache.closeAndDrain()

        #expect(throws: Never.self) {
            let loaded = try successorOutcome.get()
            #expect(loaded.result.data == Data("successor".utf8))
            #expect(loaded.observation.cacheResult == .providerLoad)
        }
        #expect(await provider.recordedContentRequestsCount() == 2)
        #expect(await provider.recordedFinishedContentLoadCountsAtRequestStart() == [0, 1])
        #expect(await provider.recordedObservedCancellationCount() == 1)
        #expect((await cache.diagnosticSnapshot).inFlightLoadCount == 0)
    }

    @Test("a successor cancelled while an abandoned provider drains starts no new read")
    func cancelledSuccessorStartsNoProviderRead() async throws {
        // Post-wait cancellation guard; this companion can pass on main.
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "cancelled-successor")
        let gate = HeldStep<Void>("abandoned provider", cancellation: .holdThroughCancellation)
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: handle, data: "cancelled-successor")],
            gate: gate,
            checksCancellationAfterGate: true
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider)
        try await abandonInitialLoaderCacheLoad(cache, handle: handle, admission: admission.context, gate: gate)
        let successor = try await startLoaderCacheSuccessor(
            cache, handle: handle, admission: admission.context, gate: gate
        )

        successor.cancel()
        gate.release()
        let successorOutcome = await successor.value
        await cache.closeAndDrain()

        expectLoaderCacheCancellation(successorOutcome)
        #expect(await provider.recordedContentRequestsCount() == 1)
        #expect(await provider.recordedFinishedContentLoadCountsAtRequestStart() == [0])
        #expect((await cache.diagnosticSnapshot).inFlightLoadCount == 0)
    }

    @Test("closing while a successor waits drains the provider and reports closed rather than cancellation")
    func closingWhileSuccessorWaitsReportsClosedAndDrains() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let handle = makeLoaderCacheHandle(content: "closed-successor")
        let gate = HeldStep<Void>("abandoned provider", cancellation: .holdThroughCancellation)
        let provider = makeLoaderCacheProvider(
            results: [makeContentResult(handle: handle, data: "closed-successor")],
            gate: gate,
            checksCancellationAfterGate: true
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider)
        try await abandonInitialLoaderCacheLoad(cache, handle: handle, admission: admission.context, gate: gate)
        let successor = try await startLoaderCacheSuccessor(
            cache, handle: handle, admission: admission.context, gate: gate
        )

        await closeLoaderCacheReleasingProvider(cache, provider: provider, gate: gate)
        let successorOutcome = await successor.value

        switch successorOutcome {
        case .success:
            Issue.record("Expected closed cache to reject the waiting successor")
        case .failure(let failure as BridgeContentLoadObservedFailure):
            #expect((failure.underlyingError as? BridgeReviewContentLoaderCacheError) == .closed)
        case .failure(let error):
            Issue.record("Expected observed closed cache error, got \(error)")
        }
        #expect(await provider.recordedContentRequestsCount() == 1)
        let snapshot = await cache.diagnosticSnapshot
        #expect(snapshot.isClosed)
        #expect(snapshot.inFlightLoadCount == 0)
        #expect(snapshot.cachedContentCount == 0)
    }

    @Test("byte-bounded LRU evicts the least recently used immutable item")
    func byteBoundedLRUEvictsLeastRecentlyUsedItem() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let firstHandle = makeLoaderCacheHandle(content: "111", itemId: "first")
        let secondHandle = makeLoaderCacheHandle(content: "222", itemId: "second")
        let thirdHandle = makeLoaderCacheHandle(content: "333", itemId: "third")
        let provider = makeLoaderCacheProvider(
            results: [
                makeContentResult(handle: firstHandle, data: "111"),
                makeContentResult(handle: secondHandle, data: "222"),
                makeContentResult(handle: thirdHandle, data: "333"),
            ]
        )
        let cache = BridgeReviewContentLoaderCache(provider: provider, contentCacheMaxBytes: 6)

        _ = try await cache.load(handle: firstHandle, productAdmission: admission.context)
        _ = try await cache.load(handle: secondHandle, productAdmission: admission.context)
        _ = try await cache.load(handle: firstHandle, productAdmission: admission.context)
        _ = try await cache.load(handle: thirdHandle, productAdmission: admission.context)
        _ = try await cache.load(handle: firstHandle, productAdmission: admission.context)
        _ = try await cache.load(handle: secondHandle, productAdmission: admission.context)

        #expect(await provider.recordedContentRequestsCount() == 4)
        #expect((await cache.diagnosticSnapshot).totalCachedBytes == 6)
    }
}

private func makeLoaderCacheHandle(
    content: String,
    itemId: String = "loader-item"
) -> BridgeContentHandle {
    makeBridgeContentHandle(
        itemId: itemId,
        role: .head,
        reviewGeneration: 7,
        contentHash: bridgeSHA256ContentHash(content),
        sizeBytes: content.utf8.count
    )
}

private func makeLoaderCacheProvider(
    results: [BridgeContentLoadResult],
    gate: HeldStep<Void>? = nil,
    checksCancellationAfterGate: Bool = false
) -> BridgeReviewSourceProviderFake {
    BridgeReviewSourceProviderFake(
        comparison: BridgeEndpointComparison(
            baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
            headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
            changedFiles: []
        ),
        contentByHandleId: Dictionary(
            results.map { ($0.handle.handleId, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        ),
        contentLoadGate: gate,
        checksCancellationAfterGate: checksCancellationAfterGate
    )
}

private func abandonInitialLoaderCacheLoad(
    _ cache: BridgeReviewContentLoaderCache,
    handle: BridgeContentHandle,
    admission: BridgeProductAdmissionContext,
    gate: HeldStep<Void>
) async throws {
    let arrival = Task { try await gate.firstArrival() }
    let original = Task {
        defer { arrival.cancel() }
        return try await cache.loadObserved(handle: handle, productAdmission: admission)
    }
    do {
        try await arrival.value
    } catch {
        gate.release()
        original.cancel()
        let outcome = await original.result
        await cache.closeAndDrain()
        Issue.record("Original load ended before provider arrival: \(outcome)")
        throw error
    }
    original.cancel()
    expectLoaderCacheCancellation(await original.result)
    #expect((await cache.diagnosticSnapshot).inFlightLoadCount == 1)
}

private func startLoaderCacheSuccessor(
    _ cache: BridgeReviewContentLoaderCache,
    handle: BridgeContentHandle,
    admission: BridgeProductAdmissionContext,
    gate: HeldStep<Void>
) async throws -> Task<Result<BridgeContentLoadObservedResult, any Error>, Never> {
    let suspension = HeldStep<Void>("successor yielded cache actor")
    let arrival = Task { try await suspension.firstArrival() }
    let successor = Task {
        defer { arrival.cancel() }
        return await loadSuccessorWithSuspensionSignal(
            cache, handle: handle, admission: admission, suspension: suspension
        )
    }
    do {
        try await arrival.value
    } catch {
        gate.release()
        suspension.release()
        successor.cancel()
        let outcome = await successor.value
        await cache.closeAndDrain()
        Issue.record("Successor ended before yielding cache actor: \(outcome)")
        throw error
    }
    return successor
}

private func loadSuccessorWithSuspensionSignal(
    _ cache: isolated BridgeReviewContentLoaderCache,
    handle: BridgeContentHandle,
    admission: BridgeProductAdmissionContext,
    suspension: HeldStep<Void>
) async -> Result<BridgeContentLoadObservedResult, any Error> {
    // This child needs the same actor. The inline load reaches its first await
    // before the child can signal; the provider gate is still held at lookup.
    let signal = Task {
        _ = cache.diagnosticSnapshot
        try await suspension.arrive(())
    }
    let outcome: Result<BridgeContentLoadObservedResult, any Error>
    do {
        outcome = .success(try await cache.loadObserved(handle: handle, productAdmission: admission))
    } catch {
        outcome = .failure(error)
    }
    suspension.release()
    _ = await signal.result
    return outcome
}

private func closeLoaderCacheReleasingProvider(
    _ cache: isolated BridgeReviewContentLoaderCache,
    provider: BridgeReviewSourceProviderFake,
    gate: HeldStep<Void>
) async {
    let releaseMilestone = HeldStep<Void>("close yielded before releasing provider")
    releaseMilestone.release()
    let release = Task {
        #expect(cache.diagnosticSnapshot.isClosed)
        try? await releaseMilestone.arrive(())
        gate.release()
    }
    await cache.closeAndDrain()
    // Synchronous snapshot: an actor hop here could let an early close finish
    // its provider after returning but before the assertion reads the count.
    #expect(provider.recordedFinishedContentLoadCount() == 1)
    // Check before joining the child: an early-returning close must fail here.
    #expect(releaseMilestone.recordedArrivals.count == 1)
    #expect(cache.diagnosticSnapshot.inFlightLoadCount == 0)
    await release.value
}

private func expectLoaderCacheCancellation(
    _ outcome: Result<BridgeContentLoadObservedResult, any Error>
) {
    switch outcome {
    case .success:
        Issue.record("Expected cancelled content load")
    case .failure(let failure as BridgeContentLoadObservedFailure):
        #expect(failure.underlyingError is CancellationError)
    case .failure(is CancellationError):
        break
    case .failure(let error):
        Issue.record("Expected cancellation, got \(error)")
    }
}
