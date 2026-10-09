import Foundation

@testable import AgentStudio
@testable import AgentStudioBridge

private struct BridgeProductWebKitLiveReviewState {
    let dom: BridgeProductWebKitCarrierDOMSnapshot
    let expectedSelectedContentHashes: String
    let initialGeneration: Int
    let itemCount: Int
    let successorGeneration: Int
}

private struct BridgeProductWebKitLiveFileState {
    let activated: Bool
    let dom: BridgeProductWebKitCarrierDOMSnapshot
    let pathSelected: Bool
}

@MainActor
extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    func collectLiveProof(
        controller: BridgePaneController,
        sourceOracle: LiveSourceOracle,
        traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    ) async throws -> BridgeProductWebKitCarrierRunResult<LiveProof> {
        guard let initialInstallation = await controller.productSessionOwner.activeInstallation else {
            throw LiveProofError.appDidNotMount
        }
        let initialWorkerInstanceId = initialInstallation.bootstrap.workerInstanceId
        return
            try await BridgeProductWebKitCarrierTestSupport
            .withHostedController(controller) { hostedController in
                hostedController.loadApp()
                guard try await waitForLiveShell(hostedController) else {
                    throw LiveProofError.appDidNotMount
                }
                let reviewState = try await collectLiveReviewState(
                    hostedController,
                    sourceOracle: sourceOracle,
                    traceRecorder: traceRecorder
                )
                let fileState = try await collectLiveFileState(
                    hostedController,
                    sourceOracle: sourceOracle
                )
                guard let installation = await hostedController.productSessionOwner.activeInstallation,
                    await installation.session.waitUntilActive()
                else { throw LiveProofError.appDidNotMount }
                guard installation.bootstrap.workerInstanceId == initialWorkerInstanceId else {
                    throw LiveProofError.workerReinstalledDuringHappyPath(
                        await BridgeProductWebKitReplacementFactTestSupport.read(hostedController.page)
                    )
                }
                guard await installation.session.waitUntilControlReplayIdle()
                else { throw LiveProofError.appDidNotMount }
                let nativeCompletionSnapshot = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(
                    hostedController)
                return LiveProof(
                    fileDOMAfterFileSwitch: fileState.dom,
                    fileModeActivated: fileState.activated,
                    filePathSelected: fileState.pathSelected,
                    initialReviewGeneration: reviewState.initialGeneration,
                    native: nativeCompletionSnapshot,
                    reviewDOMBeforeFileSwitch: reviewState.dom,
                    reviewMetadataItemCount: reviewState.itemCount,
                    reviewSelectedContentHashes: reviewState.expectedSelectedContentHashes,
                    sourceOracle: sourceOracle,
                    successorReviewGeneration: reviewState.successorGeneration,
                    trace: await traceRecorder.scrubbedTrace()
                )
            }
    }

    private func waitForLiveShell(
        _ controller: BridgePaneController
    ) async throws -> Bool {
        let navigationReady: @MainActor () -> Bool? = {
            controller.page.isLoading ? nil : true
        }
        _ = try await BridgePaneControllerEventWaits.waitForValue(
            navigationReady,
            milestone: "File and Review navigation finished",
            lastObservation: { "isLoading=\(controller.page.isLoading)" }
        )
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: "return document.querySelector('[data-testid=\"bridge-app-root\"]') === null ? null : true;",
            milestone: "File and Review app root mounted",
            lastObservation: "return document.readyState;"
        )
        let bridgeReady: @MainActor () -> Bool? = {
            controller.isBridgeReady ? true : nil
        }
        _ = try await BridgePaneControllerEventWaits.waitForValue(
            bridgeReady,
            milestone: "File and Review bridge ready",
            lastObservation: { "isBridgeReady=\(controller.isBridgeReady)" }
        )
        return controller.isBridgeReady
    }

    private func collectLiveReviewState(
        _ controller: BridgePaneController,
        sourceOracle: LiveSourceOracle,
        traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    ) async throws -> BridgeProductWebKitLiveReviewState {
        let nativePackageReady: @MainActor () -> Int? = {
            guard let package = try? controller.ipcReviewPackageSnapshot(),
                package.status == "ready",
                package.items.count >= 128
            else { return nil }
            return package.reviewGeneration
        }
        let observedGeneration: Int = try await BridgePaneControllerEventWaits.waitForValue(
            nativePackageReady,
            milestone: "native Review package has 128 items",
            lastObservation: {
                guard let package = try? controller.ipcReviewPackageSnapshot() else {
                    return "package unavailable"
                }
                return
                    "status=\(package.status),items=\(package.items.count),generation=\(String(describing: package.reviewGeneration))"
            })
        let initialPackage = try controller.ipcReviewPackageSnapshot()
        guard initialPackage.status == "ready",
            initialPackage.items.count >= 128,
            let initialGeneration = initialPackage.reviewGeneration,
            initialGeneration == observedGeneration
        else {
            throw LiveProofError.initialReviewPublicationMissing
        }
        let refresh = try await controller.refreshReviewForIPC(correlationId: nil)
        guard refresh.refreshed,
            let successorGeneration = refresh.reviewGeneration,
            successorGeneration > initialGeneration
        else {
            throw LiveProofError.successorReviewPublicationMissing
        }
        guard
            let successorPackage = controller.paneState.diff.packageMetadata,
            let selectedDescriptor = successorPackage.itemsById.values.first(where: {
                ($0.headPath ?? $0.basePath) == sourceOracle.path
            })
        else {
            throw LiveProofError.successorReviewPublicationMissing
        }
        let expectedSelectedContentHashes = selectedDescriptor.contentRoles.allHandles
            .map { "\($0.role.rawValue):\($0.contentHash)" }
            .joined(separator: ",")
        let metadataItemCount = try await waitForLiveReviewMetadataGeneration(
            controller, successorGeneration: successorGeneration, traceRecorder: traceRecorder)
        guard let reviewTrace = try await waitForLiveReviewTrace(traceRecorder),
            reviewTrace.hasReviewMetadataPublication
        else { throw LiveProofError.successorReviewPublicationMissing }
        let displayedPath = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const shell = document.querySelector('[data-testid="review-viewer-shell"]');
                const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
                const hashes = (panel?.getAttribute('data-selected-content-cache-keys') ?? '')
                  .split(',').filter(Boolean)
                  .map(entry => `${entry.split(':')[0] ?? ''}:${entry.split(':').pop() ?? ''}`)
                  .join(',');
                const path = shell?.getAttribute('data-selected-display-path');
                return shell?.getAttribute('data-selected-content-state') === 'ready'
                  && Number(panel?.getAttribute('data-selected-content-line-count') ?? '0') > 0
                  && Boolean(panel?.getAttribute('data-review-rendered-item-id') ?? panel?.getAttribute('data-selected-item-id'))
                  && path === expectedPath && hashes === expectedHashes ? path : null;
                """,
            arguments: [
                "expectedPath": sourceOracle.path,
                "expectedHashes": expectedSelectedContentHashes,
            ],
            milestone: "Review selected content rendered",
            lastObservation: """
                const shell = document.querySelector('[data-testid="review-viewer-shell"]');
                const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
                return `state=${shell?.getAttribute('data-selected-content-state') ?? 'missing'},path=${shell?.getAttribute('data-selected-display-path') ?? 'missing'},lines=${panel?.getAttribute('data-selected-content-line-count') ?? 'missing'}`;
                """
        )
        guard displayedPath as? String == sourceOracle.path else {
            throw LiveProofError.successorReviewPublicationMissing
        }
        return BridgeProductWebKitLiveReviewState(
            dom: await BridgeProductWebKitCarrierTestSupport.domSnapshot(controller.page)
                ?? .unavailable,
            expectedSelectedContentHashes: expectedSelectedContentHashes,
            initialGeneration: initialGeneration,
            itemCount: metadataItemCount,
            successorGeneration: successorGeneration
        )
    }

    private func waitForLiveReviewMetadataGeneration(
        _ controller: BridgePaneController,
        successorGeneration: Int,
        traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    ) async throws -> Int {
        let metadataValue: Any?
        do {
            metadataValue = try await WebPageEventWaits.waitForDocumentValue(
                controller.page,
                reader: """
                    const shell = document.querySelector('[data-testid="review-viewer-shell"]');
                    const itemCount = Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0');
                    const generation = Number(shell?.getAttribute('data-review-metadata-generation') ?? '0');
                    return itemCount >= minimumItems && generation === expectedGeneration ? itemCount : null;
                    """,
                arguments: ["minimumItems": 128, "expectedGeneration": successorGeneration],
                milestone: "page Review metadata generation",
                lastObservation: """
                    const shell = document.querySelector('[data-testid="review-viewer-shell"]');
                    const root = document.querySelector('[data-testid="bridge-app-root"]');
                    const reviewHost = document.querySelector('[data-testid="bridge-viewer-mode-host-review"]');
                    const diagnostic = window.__bridgeReviewSelectionDiagnostic;
                    return JSON.stringify({
                      items: shell?.getAttribute('data-review-metadata-item-count') ?? 'missing',
                      generation: shell?.getAttribute('data-review-metadata-generation') ?? 'missing',
                      rootMode: root?.getAttribute('data-bridge-viewer-mode') ?? 'missing',
                      reviewHost: reviewHost === null ? 'missing' : 'mounted',
                      reviewHostActive: reviewHost?.getAttribute('data-bridge-viewer-mode-active') ?? 'missing',
                      loadingShell: document.querySelector('[data-testid="bridge-review-metadata-loading-shell"]') !== null,
                      failedShell: document.querySelector('[data-testid="bridge-review-metadata-failed-shell"]') !== null,
                      pageReadyState: diagnostic?.pageReadyState ?? 'missing',
                      sessionState: diagnostic?.sessionState ?? 'missing',
                      replacementRequestCount: diagnostic?.replacementRequestCount ?? 0,
                      reviewInstallationGate: diagnostic?.reviewInstallationGate ?? null,
                      reviewCandidateSource: diagnostic?.reviewCandidateSource ?? null,
                      lastReviewDisplayPatch: diagnostic?.lastReviewDisplayPatch ?? null
                    });
                    """
            )
        } catch {
            let pageFailure = error
            let installation = await controller.productSessionOwner.activeInstallation
            let nativeReview = await installation?.session.reviewMilestoneSnapshot() ?? "no native session"
            let trace = await traceRecorder.scrubbedTrace()
            let reviewSamples = await traceRecorder.reviewStageSamples()
            print("PR1_REVIEW_STAGE_SAMPLES count=\(reviewSamples.count)")
            for sample in reviewSamples { print("PR1_REVIEW_STAGE_SAMPLE \(sample)") }
            let lossReadback: String
            do {
                let snapshot = try await controller.telemetrySidecarSnapshot()
                if let sidecar = snapshot.sidecar {
                    lossReadback = [
                        "required=\(sidecar.requiredLossCount)",
                        "optional=\(sidecar.optionalLossCount)",
                        "sequenceGaps=\(sidecar.sequenceGapCount)",
                        "lossDiagnostics=\(sidecar.lossDiagnostics)",
                    ].joined(separator: ",")
                } else {
                    lossReadback = "unavailable=\(String(describing: snapshot.reason))"
                }
            } catch {
                lossReadback = "snapshotFailure=\(error)"
            }
            throw BridgeWebKitMilestoneHang(
                milestone: "page Review metadata generation",
                lastObservation:
                    "pageError=\(pageFailure),native=\(nativeReview),trace=\(trace),loss=\(lossReadback)"
            )
        }
        guard let metadataItemCount = metadataValue as? Int else {
            throw LiveProofError.successorReviewPublicationMissing
        }
        return metadataItemCount
    }

    private func waitForLiveReviewTrace(
        _ recorder: BridgeProductWebKitCarrierTraceRecorder
    ) async throws -> BridgeProductWebKitCarrierTrace? {
        let initialTrace = await recorder.scrubbedTrace()
        return try await awaitBridgeWebKitMilestone(
            "Review publication trace; last=\(initialTrace)"
        ) {
            await recorder.waitForTrace(.reviewPublication)
        }
    }

    private func collectLiveFileState(
        _ controller: BridgePaneController,
        sourceOracle: LiveSourceOracle
    ) async throws -> BridgeProductWebKitLiveFileState {
        let activated = await BridgeProductWebKitCarrierTestSupport.activateFileMode(
            controller.page
        )
        guard activated else {
            return BridgeProductWebKitLiveFileState(
                activated: false,
                dom: await BridgeProductWebKitCarrierTestSupport.domSnapshot(controller.page)
                    ?? .unavailable,
                pathSelected: false
            )
        }
        // A File view becomes demanded on activation. W4's installed status
        // is the typed owner observation; the later canary proves real paint.
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
                const count = Number(shell?.getAttribute('data-file-display-item-count') ?? '0');
                return shell?.getAttribute('data-file-display-status') === 'ready'
                  && count > 0 ? count : null;
                """,
            milestone: "File display ready",
            lastObservation: """
                const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
                return `status=${shell?.getAttribute('data-file-display-status') ?? 'missing'},items=${shell?.getAttribute('data-file-display-item-count') ?? 'missing'}`;
                """
        )
        _ = try await WebPageEventWaits.waitForOpenShadowRootValue(
            controller.page,
            reader: """
                const selector = `button[data-type="item"][data-item-type="file"][data-item-path="${CSS.escape(path)}"]`;
                return findInOpenShadowRoots(document, selector) === null ? null : path;
                """,
            arguments: ["path": sourceOracle.path],
            milestone: "File path row mounted",
            lastObservation:
                "return document.querySelector('[data-testid=\"bridge-file-viewer-shell\"]')?.getAttribute('data-file-display-item-count') ?? 'missing';"
        )
        let pathSelected = await BridgeProductWebKitCarrierTestSupport.selectFilePath(
            controller.page,
            path: sourceOracle.path
        )
        if pathSelected {
            _ = try await WebPageEventWaits.waitForOpenShadowRootValue(
                controller.page,
                reader: """
                    const fileHost = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
                    return fileHost !== null && readOpenShadowRootText(fileHost).includes(canaryText)
                      ? canaryText : null;
                    """,
                arguments: ["canaryText": sourceOracle.canaryText],
                milestone: "File canary painted",
                lastObservation:
                    "return document.querySelector('[data-testid=\"bridge-viewer-mode-host-file\"]')?.textContent?.slice(0, 80) ?? 'missing';"
            )
        }
        return BridgeProductWebKitLiveFileState(
            activated: activated,
            dom: await BridgeProductWebKitCarrierTestSupport.domSnapshot(controller.page)
                ?? .unavailable,
            pathSelected: pathSelected
        )
    }
}

extension BridgeProductSession {
    func reviewMilestoneSnapshot() -> String {
        let reviewSubscriptions = subscriptionSnapshots().filter {
            $0.subscriptionKind == .reviewMetadata
        }
        let viewStates = reviewSubscriptions.flatMap { subscription in
            viewScopeByDomain.keys.filter { $0.viewId == subscription.subscriptionId }.map { domain in
                let accepted = viewScopeByDomain[domain]
                let pending = pendingReviewSnapshotByViewDomain[domain]
                return [
                    "subscription=\(subscription.subscriptionId)",
                    "scopeRevision=\(accepted?.revision.description ?? "none")",
                    "emitting=\(viewSenderState.hasActiveEmission(for: domain))",
                    "pendingTargetRevision=\(pending?.targetRevision.description ?? "none")",
                    "nextDeliverySequence=\(nextViewDeliverySequenceByDomain[domain, default: 0])",
                    "outstandingParts=\(viewSenderState.credits.outstandingPartCount(for: .view(domain)))",
                    "ackReplay=\(viewAcknowledgementReplayByDomain[domain] != nil)",
                ].joined(separator: ",")
            }
        }
        return [
            "openReviewSubscriptions=\(reviewSubscriptions.count)",
            "views=[\(viewStates.joined(separator: ";"))]",
            "nextMetadataStreamSequence=\(producerRegistry.snapshot().nextMetadataStreamSequence)",
        ].joined(separator: ",")
    }
}
