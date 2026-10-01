import AgentStudioCore
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

@Suite("File root and range enumeration outcomes")
struct BridgeWorktreeFileRootEnumerationTests {
    @Test(
        "missing roots fail instead of certifying an empty inventory",
        arguments: [false, true])
    func rootFailureCannotCertify(usePublishableManifest: Bool) async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let request = try rootEnumerationRequest(fixture: fixture, usePublishableManifest: usePublishableManifest)
        fixture.remove()
        let result = await collectRootEnumeration(request)
        #expect(result.windows.allSatisfy { !$0.isFinalWindow })
        #expect(result.failure != nil)
        #expect(result.failure as? BridgeWorktreeFileRootAccessError == .missingRoot)
        if let failure = result.failure {
            let surfaceFailure = BridgeFileSurfaceReconciler.failure(for: failure, phase: .build)
            #expect(surfaceFailure.cause == .missingRoot)
            #expect(surfaceFailure.disposition == .retryable)
            #expect(surfaceFailure.refreshFailure.retryable)
            #expect(
                BridgePaneProductMetadataCoordinator.fileRefreshDisposition(for: failure)
                    == .failed(surfaceFailure.refreshFailure))
            #expect(surfaceFailure.refreshFailure.failureKind == .fileSourceUnavailable)
            #expect(BridgePaneProductMetadataCoordinator.producerFailureReason(for: failure) == .missingRoot)
        }
    }

    @Test(
        "unreadable roots and selected ranges remain retryable source failures",
        arguments: [false, true])
    func unreadableRangeIsNotEmpty(isSelectedRange: Bool) async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 0)
        defer { fixture.remove() }
        let inaccessibleURL = isSelectedRange ? fixture.rootURL.appending(path: "locked") : fixture.rootURL
        if isSelectedRange {
            try FileManager.default.createDirectory(at: inaccessibleURL, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inaccessibleURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessibleURL.path)
        }
        let request = try rootEnumerationRequest(
            fixture: fixture, pathScope: isSelectedRange ? ["locked"] : [], usePublishableManifest: true)
        let result = await collectRootEnumeration(request)
        #expect(result.failure != nil)
        #expect(result.failure as? BridgeWorktreeFileRootAccessError == .unreadable)
        #expect(result.windows.allSatisfy { !$0.isFinalWindow })
        if let failure = result.failure {
            let surfaceFailure = BridgeFileSurfaceReconciler.failure(for: failure, phase: .build)
            #expect(surfaceFailure.cause == .unreadableRoot)
            #expect(surfaceFailure.disposition == .retryable)
            #expect(surfaceFailure.refreshFailure.retryable)
            #expect(
                BridgePaneProductMetadataCoordinator.fileRefreshDisposition(for: failure)
                    == .failed(surfaceFailure.refreshFailure))
            #expect(surfaceFailure.refreshFailure.failureKind == .fileSourceUnavailable)
            #expect(BridgePaneProductMetadataCoordinator.producerFailureReason(for: failure) == .unreadableRoot)
        }
    }

    @Test("a real successful stat cannot hide a root removed before the real list read", arguments: [false, true])
    func removedBetweenStatAndList(usePublishableManifest: Bool) async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let rootURL = fixture.rootURL
        let removed = Mutex(false)
        let attemptedList = Mutex(false)
        let reader = BridgeWorktreeFileDirectoryReader(
            entryKind: { url in
                let kind = try BridgeWorktreeFileDirectoryReader.foundation.entryKind(url)
                if url == rootURL,
                    removed.withLock({ state in
                        guard !state else { return false }
                        state = true
                        return true
                    })
                {
                    try FileManager.default.removeItem(at: rootURL)
                }
                return kind
            },
            directoryEntries: { url in
                attemptedList.withLock { $0 = true }
                return try BridgeWorktreeFileDirectoryReader.foundation.directoryEntries(url)
            })
        let request = try rootEnumerationRequest(
            fixture: fixture, usePublishableManifest: usePublishableManifest, directoryReader: reader)
        let result = await collectRootEnumeration(request)
        #expect(removed.withLock { $0 })
        #expect(attemptedList.withLock { $0 })
        #expect(result.failure as? BridgeWorktreeFileRootAccessError == .missingRoot)
        #expect(result.windows.allSatisfy { !$0.isFinalWindow })
    }

    @Test("an accessible empty root still produces a complete ready inventory")
    func existingEmptyRootCertifies() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 0)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand(foregroundPaths: [])
        try await source.open(subscription: subscription, productAdmission: fixture.productAdmission.context) { _ in }
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context, forceRecapture: false
        ) { _ in }
        let inventory = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context))
        #expect(inventory.records.isEmpty)
        #expect(inventory.isEnumerationComplete)
        #expect(inventory.memberStatus.record.status == .ready)
        #expect(try sealProductFileSourceCapture(inventory, demand: demand).mode == .snapshot)
        await source.cancel(subscriptionId: subscription.subscriptionId)
    }

    @Test("deleted-root discovery before E3 is a retryable File error and preserves healthy Review")
    func deletedRootDiscoveryKeepsReview() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let review = BridgePaneProductReviewMetadataSource()
        let package = makeReviewPackage(itemCount: 1)
        try await review.open(subscription: reviewSubscription(), productAdmission: fixture.productAdmission.context)
        let reservation = try await review.reserve(
            package: package, publicationId: reviewMetadataTestPublicationId,
            productAdmission: fixture.productAdmission.context)
        _ = try await review.deliver(
            publication: reviewMetadataCommittedPublication(package), reservation: reservation,
            productAdmission: fixture.productAdmission.context)
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: source, reviewMetadataSource: review,
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in }, refreshWorkAdmissionSource: foreground.source)
        fixture.remove()
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: Data(
                """
                {"kind":"product.call","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","workerDerivationEpoch":1,\
                "requestId":"deleted-root","requestSequence":2,\
                "call":{"method":"file.source.current","request":{}}}
                """.utf8))
        let response = await provider.response(for: request, productAdmission: fixture.productAdmission.context)
        if case .requestError(let failure) = response {
            #expect(failure.code == .internal)
            #expect(failure.retryable)
        } else {
            Issue.record("Deleted-root discovery reported availability instead of a typed File failure")
        }
        let retainedReview = try #require(
            try await applyReviewViewDemand(
                through: review, itemIds: package.orderedItemIds,
                productAdmission: fixture.productAdmission.context))
        #expect(retainedReview.snapshot.items.count == 1)
        #expect(fixture.productAdmission.context.withValidAdmission({ true }) == true)
        await review.cancel(subscriptionId: reviewSubscription().subscriptionId)
        await provider.closeAndDrain()
    }

    @Test("an invalid File root configuration is a permanent pre-E3 failure with corrective copy")
    func nonDirectoryRootIsPermanentRefusal() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator()
        let source = BridgePaneProductFileMetadataSource(
            authority: .init(
                paneId: fixture.paneId,
                worktree: .init(
                    id: fixture.worktreeId, repoId: fixture.repoId, name: "invalid-root",
                    path: fixture.demandedFileURL)),
            gitReadContext: makeBridgeGitReadContext(rootURL: fixture.demandedFileURL),
            constructionCoordinator: constructionCoordinator,
            statusProvider: ProductFileSourceStatusProvider())
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in }, refreshWorkAdmissionSource: foreground.source)
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: Data(
                """
                {"kind":"product.call","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","workerDerivationEpoch":1,\
                "requestId":"invalid-root","requestSequence":2,\
                "call":{"method":"file.source.current","request":{}}}
                """.utf8))
        let response = await provider.response(for: request, productAdmission: fixture.productAdmission.context)
        if case .requestError(let failure) = response {
            #expect(failure.code == .internal)
            #expect(!failure.retryable)
            #expect(failure.safeMessage?.isEmpty == false)
        } else {
            Issue.record("A non-directory File root was admitted instead of being refused")
        }
        await provider.closeAndDrain()
        await constructionCoordinator.shutdown()
    }
}

private func rootEnumerationRequest(
    fixture: ProductFileSourceFixture,
    pathScope: [String] = [],
    usePublishableManifest: Bool,
    directoryReader: BridgeWorktreeFileDirectoryReader = .foundation
) throws -> BridgeWorktreeFileMaterializationRequest {
    let worktree = Worktree(id: fixture.worktreeId, repoId: fixture.repoId, name: "root-read", path: fixture.rootURL)
    let spec = BridgeWorktreeFileSurfaceSourceSpec(
        clientRequestId: "root-enumeration", repoId: fixture.repoId, worktreeId: fixture.worktreeId,
        rootPathToken: worktree.stableKey, cwdScope: nil, pathScope: pathScope,
        includeStatuses: true, includeComments: false, includeAgentComms: false, freshness: .live)
    let opened = try BridgeWorktreeFileSourceProvider.openSource(
        spec: spec, worktree: worktree, subscriptionGeneration: 1)
    let policy = BridgeWorktreeFileIgnorePolicy(
        filesystemPathFilter: FilesystemPathFilter.load(forRootPath: fixture.rootURL),
        publishableFilePaths: usePublishableManifest ? [fixture.demandedPath] : nil,
        trackedPathsAndAncestors: [])
    return .init(
        rootURL: fixture.rootURL, openedSource: opened.withIgnorePolicy(policy), directoryReader: directoryReader)
}

private func collectRootEnumeration(
    _ request: BridgeWorktreeFileMaterializationRequest
) async -> (windows: [BridgeWorktreeTreeRowWindowBatch], failure: (any Error)?) {
    var windows: [BridgeWorktreeTreeRowWindowBatch] = []
    do {
        for try await window in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
            request: request, afterCount: 0, windowSize: 1)
        {
            windows.append(window)
        }
        return (windows, nil)
    } catch {
        return (windows, error)
    }
}
