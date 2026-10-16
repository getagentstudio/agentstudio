import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test
    func selectedRealGitHashMismatchEndsRenderedContentWait() async throws {
        let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-product-selected-content-failure")
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        try await seedHeavyReviewChanges(at: repoURL, trackedFileCount: 128)
        var heldProvider: BridgeProductWebKitHeldRealGitContentProvider?
        let controller = makeController(
            repoURL: repoURL,
            traceRecorder: BridgeProductWebKitCarrierTraceRecorder(),
            reviewSourceProviderTransform: { base in
                guard let shared = base as? any BridgeSharedReviewConstructionSourceProvider else {
                    preconditionFailure("Real Git reproduction requires shared construction")
                }
                let provider = BridgeProductWebKitHeldRealGitContentProvider(
                    base: shared, trackedFileURL: repoURL.appendingPathComponent("tracked.txt"))
                heldProvider = provider
                return provider
            }
        )
        let provider = try #require(heldProvider)
        // Release before launch: the provider mutates after publication at its
        // actual read boundary, with no parked read competing against live deadlines.
        provider.contentRead.release()
        _ = try #require(await controller.productSessionOwner.activeInstallation)
        try BridgeProductWebKitSelectedReviewFailureCapture.install(on: controller)
        let run = try await BridgeProductWebKitCarrierTestSupport.withHostedController(controller) { hosted in
            try #require(try await observeSelectedReadLiveShell(hosted))
            _ = try await BridgePaneControllerEventWaits.waitForValue {
                hosted.paneState.diff.status == .ready ? hosted.paneState.diff.packageMetadata : nil
            }
            let package = try #require(hosted.paneState.diff.packageMetadata)
            let selected = try #require(
                package.itemsById.values.first {
                    ($0.headPath ?? $0.basePath) == "tracked.txt"
                })
            let generation = package.reviewGeneration.rawValue
            let hashes = selected.contentRoles.allHandles
                .map { "\($0.role.rawValue):\($0.contentHash)" }.joined(separator: ",")

            let page = hosted.page
            let observeSelectedContent: @MainActor @Sendable () async throws -> Void = {
                do {
                    _ = try await BridgeProductWebKitSelectedReviewContentWait.wait(
                        page, expectedPath: "tracked.txt", expectedHashes: hashes,
                        expectedGeneration: generation, expectedItemId: selected.itemId)
                } catch is BridgeProductWebKitSelectedReviewContentFailure {
                    // A native rejection or transport failure can close before
                    // the provider is called. Do not await a nonexistent read.
                }
            }
            let readResult = try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await provider.contentReadFinished.firstArrival() }
                group.addTask { try await observeSelectedContent() }
                defer { group.cancelAll() }
                _ = try await group.next()
                return await provider.targetReadResult
            }
            let observedRead = try #require(
                readResult, "Selected content settled without a real working-tree read outcome")
            let handle = try await provider.contentRead.firstArrival()
            try #require(handle.itemId == selected.itemId)
            let failure: BridgeProviderFailure
            do {
                _ = try observedRead.get()
                Issue.record("The changed working-tree bytes unexpectedly passed the published hash")
                return false
            } catch let providerFailure as BridgeProviderFailure {
                failure = providerFailure
            }
            guard case .contentHashMismatch(let handleId, let expectedHash, let actualHash) = failure else {
                Issue.record("Unexpected real provider outcome: \(failure)")
                return false
            }
            #expect(handleId == handle.handleId)
            #expect(expectedHash == handle.contentHash)
            #expect(actualHash != expectedHash)
            _ = try await WebPageEventWaits.waitForDocumentValue(
                hosted.page,
                reader: """
                    const shell = document.querySelector('[data-testid="review-viewer-shell"]');
                    return shell?.getAttribute('data-selected-display-path') === expectedPath
                      && Number(shell?.getAttribute('data-review-metadata-generation')) === expectedGeneration
                      && shell?.getAttribute('data-selected-content-state') === 'failed' ? true : null;
                    """,
                arguments: ["expectedPath": "tracked.txt", "expectedGeneration": generation],
                milestone: "real Git selected hash mismatch published failed",
                lastObservation: BridgeProductWebKitSelectedReviewContentWait.diagnostic
            )
            let arguments: [String: Any] = [
                "expectedPath": "tracked.txt", "expectedHashes": hashes, "expectedGeneration": generation,
                "expectedItemId": selected.itemId,
            ]
            // Probe the production test's reader on the real failed DOM first.
            // The old reader returns nil here; require records red immediately
            // instead of spending the runner's inactivity bound on a known hang.
            _ = try #require(
                try await hosted.page.callJavaScript(
                    BridgeProductWebKitSelectedReviewContentWait.reader, arguments: arguments))
            return try await expectSelectedWaitFailsNamingLoadFailed(
                hosted, hashes: hashes, generation: generation, itemId: selected.itemId)
        }
        #expect(run.value)
        #expect(run.teardownSnapshot.hasZeroResidue)
    }

    /// A terminal real-git hash mismatch must fail the rendered-content wait, and the failure
    /// must name the worker's `load_failed` publication for the selected item.
    private func expectSelectedWaitFailsNamingLoadFailed(
        _ hosted: BridgePaneController, hashes: String, generation: Int, itemId: String
    ) async throws -> Bool {
        do {
            _ = try await BridgeProductWebKitSelectedReviewContentWait.wait(
                hosted.page, expectedPath: "tracked.txt", expectedHashes: hashes,
                expectedGeneration: generation, expectedItemId: itemId)
            Issue.record("A terminal selected read must fail the rendered-content wait")
            return false
        } catch let failure as BridgeProductWebKitSelectedReviewContentFailure {
            #expect(failure.path == "tracked.txt")
            #expect(failure.generation == generation)
            #expect(failure.state == "failed")
            let diagnostic = try #require(
                try JSONSerialization.jsonObject(with: Data(failure.diagnostic.utf8)) as? [String: Any])
            #expect(diagnostic["captureInstalled"] as? Bool == true)
            #expect(diagnostic["pageAvailability"] as? String == "failed")
            let workerRecords = try #require(diagnostic["correlatedWorkerAvailability"] as? [[String: Any]])
            #expect(
                workerRecords.contains { record in
                    let availability = record["availability"] as? [String: Any]
                    return record["itemId"] as? String == itemId
                        && availability?["state"] as? String == "failed"
                        && availability?["reason"] as? String == "load_failed"
                })
            #expect(failure.description.contains("load_failed"))
            return true
        }
    }

    private func observeSelectedReadLiveShell(_ hosted: BridgePaneController) async throws -> Bool {
        _ = try await loadLiveAppThroughNavigationFinish(hosted)
        do {
            return try await waitForLiveShell(hosted)
        } catch {
            let document =
                (try? await hosted.page.callJavaScript(
                    "return JSON.stringify({url: location.href, title: document.title, root: document.querySelector('[data-testid=\"bridge-app-root\"]') !== null});"
                )) as? String
            throw WebPageDocumentWaitProtocolFailure(
                detail:
                    "selected-read startup: \(error); isLoading=\(hosted.page.isLoading),url=\(String(describing: hosted.page.url)),bridgeReady=\(hosted.isBridgeReady); document=\(document ?? "unavailable")"
            )
        }
    }

}
