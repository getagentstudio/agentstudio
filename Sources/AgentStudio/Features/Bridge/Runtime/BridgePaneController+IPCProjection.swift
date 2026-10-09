import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

private struct BridgePageRenderSnapshot: Decodable {
    let pageTitle: String?
    let hasAppRoot: Bool
    let hasEmptyShell: Bool
    let hasReviewShell: Bool
    let sidebarPosition: String?
    let hasFileShell: Bool?
    let hasFileTree: Bool?
    let hasFileCodeView: Bool?
    let bridgeProtocol: String?
    let worktreeSourceState: String?
    let worktreeOpenFileState: String?
    let worktreeOpenFilePath: String?
    let worktreeRenderedFilePath: String?
    let worktreeSelectedDisplayPath: String?
    let worktreeDescriptorCount: Int?
    let worktreeTotalDescriptorCount: Int?
    let worktreeIntakeFrameCount: Int?
    let worktreeCommandCount: Int?
    let worktreeOpenSourceCommandCount: Int?
    let worktreeCodeTextLength: Int?
    let activeViewerMode: String?
    let documentVisibilityState: String?
    let frameLivenessRafAlive: String?
    let reviewMetadataGeneration: Int?
    let reviewMetadataItemCount: Int?
    let reviewMetadataTreeRowCount: Int?
    let reviewSelectedItemId: String?
    let reviewCodeTextLength: Int?
    let comparisonTriggerLabel: String?
    let comparisonTriggerDescription: String?
    let comparisonTriggerState: String?
    let comparisonTargetRevision: String?
    let comparisonSharedStartRevision: String?
    let contentTopbarFrame: IPCBridgeDOMRect?
    let contentTopbarControlsFrame: IPCBridgeDOMRect?
    let comparisonTriggerFrame: IPCBridgeDOMRect?
    let pageErrorCount: Int
    let pageErrorKinds: [String]
    let pageErrorMessages: [String]
    let productMetadataStreamDiagnostic: IPCBridgeProductMetadataStreamDiagnostic?
    let visibleHydrationStateProbe: IPCBridgeVisibleHydrationStateProbe?
    let visibleHydrationDiscardProbe: IPCBridgeVisibleHydrationDiscardProbe?
    let frameJankProbe: IPCBridgeFrameJankProbe?
}

private struct BridgePageControlProbeSnapshot: Decodable {
    let sequence: Int
    let method: String
    let status: String
    let itemId: String?
    let path: String?
    let treeSearchText: String
    let filterSurface: IPCBridgeFileTreeFilterSurface
    let gitStatusFilter: IPCBridgeGitStatusFilter
    let categoryFilter: IPCBridgeFilterCategory
    let showBinary: Bool
    let showLarge: Bool
    let renderMode: BridgePageControlRenderModeSnapshot
    let reason: String?
}

private struct BridgePageControlRenderModeSnapshot: Decodable {
    let kind: String
}

@MainActor
extension BridgePaneController {
    package func ipcReviewPackageSnapshot() throws -> IPCBridgeReviewPackageResult {
        let package = paneState.diff.packageMetadata
        let items = try package.map(ipcReviewItemSummaries) ?? []
        let result = IPCBridgeReviewPackageResult(
            paneId: paneId,
            status: paneState.diff.status.rawValue,
            error: paneState.diff.error,
            selectedItemId: selectedReviewItemId,
            packageId: package?.packageId,
            reviewGeneration: package?.reviewGeneration.rawValue,
            revision: package?.revision,
            summary: package.map(ipcPackageSummary),
            comparisonOrigin: package?.comparisonOrigin.map(ipcComparisonOrigin),
            reviewedSubjectLabel: package?.reviewedSubjectLabel,
            items: items
        )
        try BridgeIPCResponseBudget.validate(result)
        return result
    }

    package func refreshReviewForIPC(correlationId: UUID?) async throws -> IPCBridgeReviewRefreshResult {
        guard let worktreeId = runtime.metadata.worktreeId else {
            throw BridgeIPCProjectionError(reason: .packageUnavailable)
        }

        let commandId = UUID()
        let result = await handleDiffCommand(
            .loadDiff(
                DiffArtifact(
                    diffId: UUIDv7.generate(),
                    worktreeId: worktreeId,
                    patchData: Data()
                )
            ),
            commandId: commandId,
            correlationId: correlationId
        )

        switch result {
        case .success, .queued:
            return IPCBridgeReviewRefreshResult(
                paneId: paneId,
                refreshed: paneState.diff.status == .ready,
                status: paneState.diff.status.rawValue,
                packageId: paneState.diff.packageMetadata?.packageId,
                reviewGeneration: paneState.diff.packageMetadata?.reviewGeneration.rawValue,
                correlationId: correlationId
            )
        case .failure:
            throw BridgeIPCProjectionError(reason: .packageUnavailable)
        }
    }

    package func renderStateForIPC() async throws -> IPCBridgeRenderStateResult {
        let productSession = await productSessionDiagnosticForIPC()
        let refreshAdmission = refreshAdmissionCoordinator.diagnosticSnapshot
        do {
            let result = try await page.callJavaScript(Self.renderStateJavaScript)
            guard let json = result as? String, let data = json.data(using: .utf8) else {
                return makeRenderStateFailureResult(
                    reason: "render_state_result_not_string",
                    detail: String(describing: result),
                    productSession: productSession,
                    refreshAdmission: refreshAdmission
                )
            }
            let snapshot = try JSONDecoder().decode(BridgePageRenderSnapshot.self, from: data)
            return IPCBridgeRenderStateResult(
                paneId: paneId,
                summary: IPCBridgeRenderSummary(
                    pageTitle: snapshot.pageTitle,
                    hasAppRoot: snapshot.hasAppRoot,
                    hasEmptyShell: snapshot.hasEmptyShell,
                    hasReviewShell: snapshot.hasReviewShell,
                    sidebarPosition: snapshot.sidebarPosition,
                    hasFileShell: snapshot.hasFileShell,
                    hasFileTree: snapshot.hasFileTree,
                    hasFileCodeView: snapshot.hasFileCodeView,
                    bridgeProtocol: snapshot.bridgeProtocol,
                    worktreeSourceState: snapshot.worktreeSourceState,
                    worktreeOpenFileState: snapshot.worktreeOpenFileState,
                    worktreeOpenFilePath: snapshot.worktreeOpenFilePath,
                    worktreeRenderedFilePath: snapshot.worktreeRenderedFilePath,
                    worktreeSelectedDisplayPath: snapshot.worktreeSelectedDisplayPath,
                    worktreeDescriptorCount: snapshot.worktreeDescriptorCount,
                    worktreeTotalDescriptorCount: snapshot.worktreeTotalDescriptorCount,
                    worktreeIntakeFrameCount: snapshot.worktreeIntakeFrameCount,
                    worktreeCommandCount: snapshot.worktreeCommandCount,
                    worktreeOpenSourceCommandCount: snapshot.worktreeOpenSourceCommandCount,
                    worktreeCodeTextLength: snapshot.worktreeCodeTextLength,
                    activeViewerMode: snapshot.activeViewerMode,
                    documentVisibilityState: snapshot.documentVisibilityState,
                    frameLivenessRafAlive: snapshot.frameLivenessRafAlive,
                    reviewMetadataGeneration: snapshot.reviewMetadataGeneration,
                    reviewMetadataItemCount: snapshot.reviewMetadataItemCount,
                    reviewMetadataTreeRowCount: snapshot.reviewMetadataTreeRowCount,
                    reviewSelectedItemId: snapshot.reviewSelectedItemId,
                    reviewCodeTextLength: snapshot.reviewCodeTextLength,
                    comparisonTriggerLabel: snapshot.comparisonTriggerLabel,
                    comparisonTriggerDescription: snapshot.comparisonTriggerDescription,
                    comparisonTriggerState: snapshot.comparisonTriggerState,
                    comparisonTargetRevision: snapshot.comparisonTargetRevision,
                    comparisonSharedStartRevision: snapshot.comparisonSharedStartRevision,
                    contentTopbarFrame: snapshot.contentTopbarFrame,
                    contentTopbarControlsFrame: snapshot.contentTopbarControlsFrame,
                    comparisonTriggerFrame: snapshot.comparisonTriggerFrame,
                    visibleHydrationStateProbe: snapshot.visibleHydrationStateProbe,
                    visibleHydrationDiscardProbe: snapshot.visibleHydrationDiscardProbe,
                    frameJankProbe: snapshot.frameJankProbe
                ),
                diagnostics: IPCBridgeRenderDiagnostics(
                    evaluateSucceeded: true,
                    pageErrorCount: snapshot.pageErrorCount,
                    pageErrorKinds: snapshot.pageErrorKinds,
                    pageErrorMessages: snapshot.pageErrorMessages,
                    nativeActivity: ipcNativeActivity(refreshAdmission.activity),
                    foregroundWorkEpoch: refreshAdmission.foregroundWorkEpoch,
                    dirtyFactPresent: refreshAdmission.dirtyFact != nil,
                    activeRefreshPassPresent: refreshAdmission.activeRefreshPass != nil,
                    refreshPassCount: refreshAdmission.refreshPassCount,
                    productMetadataStream: snapshot.productMetadataStreamDiagnostic,
                    productSession: productSession
                ),
                visibleHydrationStateProbe: snapshot.visibleHydrationStateProbe,
                visibleHydrationDiscardProbe: snapshot.visibleHydrationDiscardProbe,
                frameJankProbe: snapshot.frameJankProbe
            )
        } catch {
            return makeRenderStateFailureResult(
                reason: "render_state_evaluation_failed",
                detail: "\(error)",
                productSession: productSession,
                refreshAdmission: refreshAdmission
            )
        }
    }

    package func selectReviewItemForIPC(
        itemId: String,
        correlationId: UUID?
    ) async throws -> IPCBridgeReviewSelectFileResult {
        guard let paneAdmission = productAdmissionGate.acquire(),
            let installation = productSessionOwner.installationFenceProjection.snapshot.installation,
            let productAdmission = paneAdmission.withInstallation(installation.gate),
            let publication = reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        else {
            throw BridgeIPCProjectionError(reason: .packageUnavailable)
        }
        let package = publication.package
        guard package.itemsById[itemId] != nil else {
            throw BridgeIPCProjectionError(reason: .itemNotFound)
        }

        try await requestReviewTargetAndPublish(
            source: BridgeProductNavigationReviewSource(
                generation: package.reviewGeneration.rawValue,
                metadataSourceId: package.query.queryId,
                packageId: package.packageId
            ),
            target: BridgeProductNavigationReviewTarget(reviewItemId: itemId)
        )
        selectedReviewItemId = itemId
        return IPCBridgeReviewSelectFileResult(
            paneId: paneId,
            itemId: itemId,
            selected: true,
            correlationId: correlationId
        )
    }

    package func applyPageControlForIPC(
        _ command: IPCBridgePageControlCommand,
        correlationId: UUID?
    ) async throws -> IPCBridgePageControlResult {
        let commandLiteral = try javaScriptLiteral(command)
        let methodLiteral = try javaScriptStringLiteral(command.method)
        let result = try await page.callJavaScript(
            """
            return JSON.stringify((() => {
              window.bridgeReviewControlProbe = undefined;
              window.dispatchEvent(new CustomEvent('__bridge_review_control', {
                detail: \(commandLiteral)
              }));
              const nextProbe = window.bridgeReviewControlProbe || null;
              return nextProbe || {
                sequence: -1,
                method: \(methodLiteral),
                status: 'rejected',
                itemId: null,
                path: null,
                treeSearchText: '',
                filterSurface:
                  \(commandLiteral).method === 'bridge.fileTree.setFilter'
                    ? \(commandLiteral).filter.surface
                    : 'review',
                gitStatusFilter: 'all',
                categoryFilter:
                  \(commandLiteral).method === 'bridge.fileTree.setFilter'
                    ? \(commandLiteral).filter.categoryFilter
                    : 'all',
                showBinary: false,
                showLarge: false,
                renderMode: { kind: 'codeView' },
                reason: 'missing_control_probe'
              };
            })())
            """,
            contentWorld: .page
        )
        guard let json = result as? String, let data = json.data(using: .utf8) else {
            throw BridgeIPCProjectionError(reason: .validationRejected)
        }
        let snapshot = try JSONDecoder().decode(BridgePageControlProbeSnapshot.self, from: data)
        guard snapshot.method == command.method, snapshot.sequence >= 0 else {
            throw BridgeIPCProjectionError(reason: .validationRejected)
        }
        return IPCBridgePageControlResult(
            paneId: paneId,
            method: snapshot.method,
            status: snapshot.status,
            itemId: snapshot.itemId,
            path: snapshot.path,
            treeSearchText: snapshot.treeSearchText,
            filterSurface: snapshot.filterSurface,
            gitStatusFilter: snapshot.gitStatusFilter,
            categoryFilter: snapshot.categoryFilter,
            showBinary: snapshot.showBinary,
            showLarge: snapshot.showLarge,
            renderMode: snapshot.renderMode.kind,
            reason: snapshot.reason,
            correlationId: correlationId
        )
    }

    package func loadContentForIPC(
        contentHandleId: String,
        reviewGeneration: Int
    ) async throws -> IPCBridgeContentGetResult {
        guard let paneAdmission = productAdmissionGate.acquire(),
            let installation = productSessionOwner.installationFenceProjection.snapshot.installation,
            let productAdmission = paneAdmission.withInstallation(installation.gate)
        else {
            throw BridgeIPCProjectionError(reason: .contentUnavailable)
        }
        let requestedGeneration = BridgeReviewGeneration(reviewGeneration)
        guard
            let publication = reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            ),
            publication.package.reviewGeneration == requestedGeneration,
            let contentLease = reviewPublicationCoordinator.acquireContentLease(
                handleId: contentHandleId,
                packageId: publication.package.packageId,
                requestedGeneration: requestedGeneration,
                sourceIdentity: publication.package.query.queryId,
                productAdmission: productAdmission
            )
        else {
            throw BridgeIPCProjectionError(reason: .contentUnavailable)
        }
        defer { reviewPublicationCoordinator.settleContentLease(contentLease) }
        let handle = contentLease.handle
        guard
            reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )?.publicationId == publication.publicationId
        else {
            throw BridgeIPCProjectionError(reason: .contentUnavailable)
        }
        guard
            let ipcResult = try productAdmission.withValidAdmission({ () throws -> IPCBridgeContentGetResult in
                guard handle.reviewGeneration == requestedGeneration else {
                    throw BridgeIPCProjectionError(reason: .contentUnavailable)
                }

                let result = IPCBridgeContentGetResult(
                    paneId: paneId,
                    handle: ipcContentHandle(handle),
                    mimeType: handle.mimeType
                )
                try BridgeIPCResponseBudget.validate(result)
                return result
            })
        else {
            throw BridgeIPCProjectionError(reason: .contentUnavailable)
        }
        return ipcResult
    }

    package func flushTelemetryForIPC() async throws -> IPCBridgeTelemetryFlushResult {
        guard let telemetrySessionOwner else {
            return IPCBridgeTelemetryFlushResult(
                paneId: paneId,
                kind: .unavailable,
                unavailableReason: .disabled,
                report: nil,
                drained: nil
            )
        }
        let proofInstallation = await telemetrySessionOwner.installation
        let proofSession = proofInstallation.session
        let proofCaptureID = await proofSession.beginProofSnapshotCapture()
        let sidecar: BridgeTelemetrySidecarDrainEnvelope
        do {
            sidecar = try await drainTelemetrySidecar(closeAfterDrain: false)
        } catch {
            await proofSession.cancelProofSnapshotCapture(proofCaptureID)
            throw error
        }
        guard
            sidecar.kind == .report,
            let telemetrySessionId = sidecar.telemetrySessionId,
            let sidecarReport = sidecar.sidecar
        else {
            await proofSession.cancelProofSnapshotCapture(proofCaptureID)
            return IPCBridgeTelemetryFlushResult(
                paneId: paneId,
                kind: .unavailable,
                unavailableReason: sidecar.reason == .disabled ? .disabled : .failed,
                report: nil,
                drained: nil
            )
        }
        guard
            let native = await proofSession.takeProofSnapshot(
                for: proofCaptureID,
                acceptedBatchSequence: sidecarReport.acceptedBatchSequence
            )
        else {
            return IPCBridgeTelemetryFlushResult(
                paneId: paneId,
                kind: .unavailable,
                unavailableReason: .failed,
                report: nil,
                drained: nil
            )
        }
        let report = BridgeTelemetryProofReport.drain(
            telemetrySessionId: telemetrySessionId,
            sidecar: sidecarReport,
            expectedSettlementDisposition: .reopened,
            native: native
        )
        try await recordTelemetrySidecarProof(
            report: report,
            phase: .nonterminalReopened,
            expectedSettlementDisposition: .reopened
        )
        return IPCBridgeTelemetryFlushResult(
            paneId: paneId,
            kind: .report,
            unavailableReason: nil,
            report: report,
            drained:
                sidecarReport.type == .drained
                && sidecarReport.settlementDisposition == .reopened
        )
    }

    package func telemetrySnapshotForIPC() async throws -> IPCBridgeTelemetrySnapshotResult {
        guard let telemetrySessionOwner else {
            return IPCBridgeTelemetrySnapshotResult(
                paneId: paneId,
                kind: .unavailable,
                unavailableReason: .disabled,
                report: nil
            )
        }
        let sidecar = try await telemetrySidecarSnapshot()
        guard
            sidecar.kind == .report,
            let telemetrySessionId = sidecar.telemetrySessionId,
            let sidecarReport = sidecar.sidecar
        else {
            return IPCBridgeTelemetrySnapshotResult(
                paneId: paneId,
                kind: .unavailable,
                unavailableReason: sidecar.reason == .disabled ? .disabled : .failed,
                report: nil
            )
        }
        let native = await telemetrySessionOwner.snapshot
        return IPCBridgeTelemetrySnapshotResult(
            paneId: paneId,
            kind: .report,
            unavailableReason: nil,
            report: BridgeTelemetryProofReport.snapshot(
                telemetrySessionId: telemetrySessionId,
                sidecar: sidecarReport,
                native: native
            )
        )
    }

    private nonisolated static var renderStateJavaScript: String {
        """
        return JSON.stringify((() => {
          const errorProbe = Array.isArray(window.__bridgeErrorProbe)
            ? window.__bridgeErrorProbe
            : [];
          const clip = (value, limit) => String(value ?? '').slice(0, limit);
          const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
          const contentTopbar = document.querySelector('[data-testid="bridge-viewer-content-topbar"]');
          const contentTopbarControls = document.querySelector(
            '[data-testid="bridge-viewer-content-topbar-controls"]'
          );
          const comparisonTrigger = document.querySelector(
            '[data-testid="bridge-review-comparison-trigger"]'
          );
          const comparisonCurrentState = document.querySelector(
            '[data-testid="bridge-review-comparison-current-state"]'
          );
          const comparisonEffectiveRevision = document.querySelector(
            '[data-testid="bridge-review-comparison-effective-revision"]'
          );
          const fileShell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
          const fileTree = document.querySelector('[data-testid="bridge-file-viewer-pierre-file-tree"]');
          const fileCodeCanvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
          const fileCodeView = document.querySelector('[data-testid="bridge-file-viewer-code-view"]');
          const filterCountText =
            document.querySelector('[data-testid="worktree-file-filter-count"]')?.textContent || '0/0';
          const worktreeDescriptorCount = Number(filterCountText.split('/')[0] || '0');
          const worktreeTotalDescriptorCount = Number(filterCountText.split('/')[1] || '0');
          const intakeProbe = Array.isArray(window.__bridgeIntakeProbe)
            ? window.__bridgeIntakeProbe
            : [];
          const commandProbe = Array.isArray(window.__bridgeCommandProbe)
            ? window.__bridgeCommandProbe
            : [];
          const finiteNumberOrNull = (value) => {
            const number = Number(value);
            return Number.isFinite(number) ? number : null;
          };
          const finiteIntegerOrNull = (value) => {
            const number = finiteNumberOrNull(value);
            return number === null ? null : Math.trunc(number);
          };
          const nonnegativeIntegerOrNull = (value) => {
            const integer = finiteIntegerOrNull(value);
            return integer === null || integer < 0 ? null : integer;
          };
          const booleanOrNull = (value) => typeof value === 'boolean' ? value : null;
          const enumStringOrNull = (value, allowedValues) => {
            return typeof value === 'string' && allowedValues.includes(value) ? value : null;
          };
          const clippedNonemptyStringOrNull = (value, limit) => {
            if (typeof value !== 'string') return null;
            const clippedValue = value.slice(0, limit);
            return clippedValue.length > 0 ? clippedValue : null;
          };
          const objectOrNull = (value) => {
            return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
          };
          const rectOrNull = (element) => {
            if (element === null) return null;
            const rect = element.getBoundingClientRect();
            const x = finiteNumberOrNull(rect.x);
            const y = finiteNumberOrNull(rect.y);
            const width = finiteNumberOrNull(rect.width);
            const height = finiteNumberOrNull(rect.height);
            return x === null || y === null || width === null || height === null
              ? null
              : { x, y, width, height };
          };
          const rawVisibleHydrationStateProbe = objectOrNull(window.__bridgeVisibleHydrationStateProbe);
          const visibleHydrationStateProbe = rawVisibleHydrationStateProbe === null
            ? null
            : {
                reportedVisibleItemCount: finiteIntegerOrNull(
                  rawVisibleHydrationStateProbe.reportedVisibleItemCount
                ),
                trackedVisibleItemCount: finiteIntegerOrNull(
                  rawVisibleHydrationStateProbe.trackedVisibleItemCount
                ),
                truncatedVisibleItemCount: finiteIntegerOrNull(
                  rawVisibleHydrationStateProbe.truncatedVisibleItemCount
                ),
                untrackedItemCount: finiteIntegerOrNull(rawVisibleHydrationStateProbe.untrackedItemCount),
                loadingItemCount: finiteIntegerOrNull(rawVisibleHydrationStateProbe.loadingItemCount),
                readyItemCount: finiteIntegerOrNull(rawVisibleHydrationStateProbe.readyItemCount),
                failedItemCount: finiteIntegerOrNull(rawVisibleHydrationStateProbe.failedItemCount),
                deferredItemCount: finiteIntegerOrNull(rawVisibleHydrationStateProbe.deferredItemCount),
                abortedItemCount: finiteIntegerOrNull(rawVisibleHydrationStateProbe.abortedItemCount),
                pausedNow: booleanOrNull(rawVisibleHydrationStateProbe.pausedNow)
              };
          const rawVisibleHydrationDiscardProbe = objectOrNull(window.__bridgeVisibleHydrationDiscardProbe);
          const visibleHydrationDiscardProbe = rawVisibleHydrationDiscardProbe === null
            ? null
            : {
                readyResultDiscardCount: finiteIntegerOrNull(
                  rawVisibleHydrationDiscardProbe.readyResultDiscardCount
                ),
                records: Array.isArray(rawVisibleHydrationDiscardProbe.records)
                  ? rawVisibleHydrationDiscardProbe.records.slice(-20).map((record) => {
                      const entry = objectOrNull(record) || {};
                      return {
                        hadState: booleanOrNull(entry.hadState),
                        pausedNow: booleanOrNull(entry.pausedNow)
                      };
                    })
                  : []
              };
          const rawFrameJankProbe = objectOrNull(window.__bridgeFrameJankProbe);
          const rawLongTask = objectOrNull(rawFrameJankProbe?.long_task) || {};
          const rawDroppedFrame = objectOrNull(rawFrameJankProbe?.dropped_frame) || {};
          const frameJankProbe = rawFrameJankProbe === null
            ? null
            : {
                longTask: {
                  count: finiteIntegerOrNull(rawLongTask.count),
                  totalMs: finiteNumberOrNull(rawLongTask.total_ms),
                  maxMs: finiteNumberOrNull(rawLongTask.max_ms)
                },
                droppedFrame: {
                  count: finiteIntegerOrNull(rawDroppedFrame.count),
                  worstGapMs: finiteNumberOrNull(rawDroppedFrame.worst_gap_ms)
                },
                lastLongTaskAtMs: finiteNumberOrNull(rawFrameJankProbe.last_long_task_at_ms)
              };
          const rawProductMetadataStreamDiagnostic = objectOrNull(
            window.__bridgeProductMetadataStreamDiagnostic
          );
          const productMetadataStreamDiagnostic =
            rawProductMetadataStreamDiagnostic?.kind === 'productMetadataStream'
              ? {
                  kind: 'productMetadataStream',
                  routeFailureSubscriptionId: clip(rawProductMetadataStreamDiagnostic.routeFailureSubscriptionId, 128) || null,
                  lastSubscriptionTermination: objectOrNull(rawProductMetadataStreamDiagnostic.lastSubscriptionTermination) === null
                    ? null
                    : {
                        subscriptionId: clip(rawProductMetadataStreamDiagnostic.lastSubscriptionTermination.subscriptionId, 128) || null,
                        outcome: enumStringOrNull(rawProductMetadataStreamDiagnostic.lastSubscriptionTermination.outcome, ['terminal', 'failed']),
                        reason: clip(rawProductMetadataStreamDiagnostic.lastSubscriptionTermination.reason, 80) || null
                      },
                  acknowledgedFrameCount: nonnegativeIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.acknowledgedFrameCount
                  ),
                  activeSubscriptionCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.activeSubscriptionCount
                  ),
                  committedFrameCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.committedFrameCount
                  ),
                  decoderState: clip(rawProductMetadataStreamDiagnostic.decoderState, 40) || null,
                  expectedNextStreamSequence: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.expectedNextStreamSequence
                  ),
                  failureCode: clip(rawProductMetadataStreamDiagnostic.failureCode, 80) || null,
                  failureStage: clip(rawProductMetadataStreamDiagnostic.failureStage, 40) || null,
                  identityMismatchField:
                    clip(rawProductMetadataStreamDiagnostic.identityMismatchField, 80) || null,
                  lastChunkByteCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.lastChunkByteCount
                  ),
                  lastAcknowledgedStreamSequence: nonnegativeIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.lastAcknowledgedStreamSequence
                  ),
                  lastCommittedFrameKind:
                    clip(rawProductMetadataStreamDiagnostic.lastCommittedFrameKind, 80) || null,
                  lastRoutedFrameKind:
                    clip(rawProductMetadataStreamDiagnostic.lastRoutedFrameKind, 80) || null,
                  lifecycleState:
                    clip(rawProductMetadataStreamDiagnostic.lifecycleState, 40) || null,
                  peakRetainedByteCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.peakRetainedByteCount
                  ),
                  pushCount: finiteIntegerOrNull(rawProductMetadataStreamDiagnostic.pushCount),
                  readFulfilledCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.readFulfilledCount
                  ),
                  readPending: booleanOrNull(rawProductMetadataStreamDiagnostic.readPending),
                  readRequestCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.readRequestCount
                  ),
                  receivedByteCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.receivedByteCount
                  ),
                  retainedByteCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.retainedByteCount
                  ),
                  routeFailureCode:
                    clip(rawProductMetadataStreamDiagnostic.routeFailureCode, 80) || null,
                  routedFrameCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.routedFrameCount
                  ),
                  streamOpenCount: finiteIntegerOrNull(
                    rawProductMetadataStreamDiagnostic.streamOpenCount
                  )
                }
              : null;
          const diffContainers = [...document.querySelectorAll('diffs-container')];
          const codeViewShadowText = diffContainers
            .map((element) => element.shadowRoot?.textContent || '')
            .join(' ');
          const activeViewerModeHost = document.querySelector(
            '[data-bridge-viewer-mode-active="true"]'
          );
          const activeViewerMode = enumStringOrNull(
            activeViewerModeHost?.getAttribute('data-bridge-viewer-mode-host'),
            ['review', 'file']
          );
          const documentVisibilityState = enumStringOrNull(
            document.visibilityState,
            ['visible', 'hidden']
          );
          const frameLivenessRafAlive = enumStringOrNull(
            objectOrNull(window.__bridgeFrameLivenessProbe)?.rafAlive,
            ['true', 'false', 'unknown']
          );
          const reviewMetadataGeneration = reviewShell === null
            ? null
            : nonnegativeIntegerOrNull(
                reviewShell.getAttribute('data-review-metadata-generation')
              );
          const reviewMetadataItemCount = reviewShell === null
            ? null
            : nonnegativeIntegerOrNull(
                reviewShell.getAttribute('data-review-metadata-item-count')
              );
          const reviewMetadataTreeRowCount = reviewShell === null
            ? null
            : nonnegativeIntegerOrNull(
                reviewShell.getAttribute('data-review-metadata-tree-row-count')
              );
          const reviewCodePanel = document.querySelector('[data-testid="bridge-code-view-panel"]');
          const reviewSelectedItemId = clippedNonemptyStringOrNull(
            reviewCodePanel?.getAttribute('data-selected-item-id'),
            512
          );
          const reviewDiffContainers = reviewCodePanel === null
            ? []
            : [...reviewCodePanel.querySelectorAll('diffs-container')];
          const reviewCodeTextLength = reviewCodePanel === null
            ? null
            : reviewDiffContainers
                .map((element) => element.shadowRoot?.textContent || '')
                .join(' ')
                .length;
          const comparisonDescriptionId = clippedNonemptyStringOrNull(
            comparisonTrigger?.getAttribute('aria-describedby'),
            256
          );
          const comparisonDescription = comparisonDescriptionId === null
            ? null
            : document.getElementById(comparisonDescriptionId);
          const comparisonTriggerLabel = clippedNonemptyStringOrNull(
            comparisonTrigger?.getAttribute('aria-label') || comparisonTrigger?.textContent,
            256
          );
          const comparisonTriggerDescription = clippedNonemptyStringOrNull(
            comparisonDescription?.textContent,
            1024
          );
          const comparisonTriggerState = comparisonTrigger === null
            ? null
            : comparisonTrigger.hasAttribute('data-popup-open') ? 'open' : 'closed';
          const fileCodeText = `${fileCodeCanvas?.textContent || ''} ${codeViewShadowText}`;
          const pageErrorKinds = Array.from(new Set(errorProbe.slice(-8).map((entry) => {
            return clip(entry.kind, 80);
          }).filter((kind) => kind.length > 0)));
          const pageErrorMessages = errorProbe.slice(-4).map((entry) => {
            const kind = clip(entry.kind, 80);
            const message = clip(entry.message, 300);
            const stack = clip(entry.stack, 500);
            return [kind, message, stack].filter((part) => part.length > 0).join(': ');
          }).filter((message) => message.length > 0);
          return {
            pageTitle: document.title || null,
            hasAppRoot: document.querySelector('[data-testid="bridge-app-root"]') !== null,
            hasEmptyShell: document.querySelector('[data-testid="bridge-review-empty-shell"]') !== null,
            hasReviewShell: reviewShell !== null,
            sidebarPosition: reviewShell?.getAttribute('data-sidebar-position') || null,
            hasFileShell: fileShell !== null,
            hasFileTree: fileTree !== null,
            hasFileCodeView: fileCodeView !== null,
            bridgeProtocol: document.documentElement.getAttribute('data-bridge-app-protocol') || null,
            worktreeSourceState: fileShell?.getAttribute('data-worktree-source-state') || null,
            worktreeOpenFileState: fileCodeCanvas?.getAttribute('data-worktree-open-file-state') || null,
            worktreeOpenFilePath: fileCodeCanvas?.getAttribute('data-worktree-open-file-path') || null,
            worktreeRenderedFilePath: fileCodeCanvas?.getAttribute('data-worktree-rendered-file-path') || null,
            worktreeSelectedDisplayPath: fileShell?.getAttribute('data-selected-display-path') || null,
            worktreeDescriptorCount,
            worktreeTotalDescriptorCount,
            worktreeIntakeFrameCount: intakeProbe.length,
            worktreeCommandCount: commandProbe.length,
            worktreeOpenSourceCommandCount: 0,
            worktreeCodeTextLength: fileCodeText.length,
            activeViewerMode,
            documentVisibilityState,
            frameLivenessRafAlive,
            reviewMetadataGeneration,
            reviewMetadataItemCount,
            reviewMetadataTreeRowCount,
            reviewSelectedItemId,
            reviewCodeTextLength,
            comparisonTriggerLabel,
            comparisonTriggerDescription,
            comparisonTriggerState,
            comparisonTargetRevision: clippedNonemptyStringOrNull(
              comparisonCurrentState?.getAttribute('data-resolved-target-oid'),
              128
            ),
            comparisonSharedStartRevision: clippedNonemptyStringOrNull(
              comparisonEffectiveRevision?.getAttribute('title'),
              128
            ),
            contentTopbarFrame: rectOrNull(contentTopbar),
            contentTopbarControlsFrame: rectOrNull(contentTopbarControls),
            comparisonTriggerFrame: rectOrNull(comparisonTrigger),
            pageErrorCount: errorProbe.length,
            pageErrorKinds,
            pageErrorMessages,
            productMetadataStreamDiagnostic,
            visibleHydrationStateProbe,
            visibleHydrationDiscardProbe,
            frameJankProbe
          };
        })())
        """
    }

    private func makeRenderStateFailureResult(
        reason: String,
        detail: String,
        productSession: IPCBridgeProductSessionDiagnostic,
        refreshAdmission: BridgePaneRefreshAdmissionSnapshot
    ) -> IPCBridgeRenderStateResult {
        IPCBridgeRenderStateResult(
            paneId: paneId,
            summary: IPCBridgeRenderSummary(
                pageTitle: page.title,
                hasAppRoot: false,
                hasEmptyShell: false,
                hasReviewShell: false,
                sidebarPosition: nil
            ),
            diagnostics: IPCBridgeRenderDiagnostics(
                evaluateSucceeded: false,
                pageErrorCount: 1,
                pageErrorKinds: [reason],
                pageErrorMessages: [detail],
                nativeActivity: ipcNativeActivity(refreshAdmission.activity),
                foregroundWorkEpoch: refreshAdmission.foregroundWorkEpoch,
                dirtyFactPresent: refreshAdmission.dirtyFact != nil,
                activeRefreshPassPresent: refreshAdmission.activeRefreshPass != nil,
                refreshPassCount: refreshAdmission.refreshPassCount,
                productSession: productSession
            )
        )
    }

    private func productSessionDiagnosticForIPC() async -> IPCBridgeProductSessionDiagnostic {
        let snapshot = await productSessionOwner.snapshot()
        return IPCBridgeProductSessionDiagnostic(
            activeProducerCount: snapshot.activeProducerCount,
            activeProducerTaskCount: snapshot.activeProducerTaskCount,
            activeContentLeaseCount: snapshot.activeContentLeaseCount,
            queuedFrameCount: snapshot.queuedFrameCount,
            queuedByteCount: snapshot.queuedByteCount,
            pendingFrameWaiterCount: snapshot.pendingFrameWaiterCount,
            inFlightFrameReceiptCount: snapshot.inFlightFrameReceiptCount,
            pendingLifecycleAcknowledgementCount: snapshot.pendingLifecycleAcknowledgementCount,
            nextMetadataStreamSequence: snapshot.nextMetadataStreamSequence
        )
    }

    private func ipcNativeActivity(
        _ activity: BridgePaneActivity
    ) -> IPCBridgeNativeActivity {
        switch activity {
        case .foreground:
            .foreground
        case .loadedHidden:
            .loadedHidden
        case .dormant:
            .dormant
        case .closed:
            .closed
        }
    }

    private func ipcPackageSummary(_ package: BridgeReviewPackage) -> IPCBridgeReviewPackageSummary {
        IPCBridgeReviewPackageSummary(
            filesChanged: package.summary.filesChanged,
            additions: package.summary.additions,
            deletions: package.summary.deletions,
            visibleFileCount: package.summary.visibleFileCount,
            hiddenFileCount: package.summary.hiddenFileCount
        )
    }

    private func ipcComparisonOrigin(
        _ origin: BridgeReviewComparisonOrigin
    ) -> IPCBridgeReviewComparisonOrigin {
        switch origin {
        case .contribution(let contribution):
            .contribution(
                IPCBridgeReviewContributionOrigin(
                    symbolicTarget: ipcComparisonTarget(contribution.symbolicTarget),
                    resolvedTargetOID: contribution.resolvedTargetOID,
                    reviewedHeadOID: contribution.reviewedHeadOID,
                    baseRole: ipcComparisonBaseRole(contribution.baseRole),
                    baseOID: contribution.baseOID
                )
            )
        }
    }

    private func ipcComparisonTarget(
        _ target: WorkspaceReviewContributionTarget
    ) -> IPCBridgeReviewComparisonTarget {
        switch target {
        case .localDefaultBranch(let branchName, let basis):
            .localDefaultBranch(branchName: branchName, basis: ipcComparisonBasis(basis))
        case .originDefaultBranch(let remoteName, let branchName, let basis):
            .originDefaultBranch(
                remoteName: remoteName,
                branchName: branchName,
                basis: ipcComparisonBasis(basis)
            )
        case .branch(let name, let basis):
            .branch(name: name, basis: ipcComparisonBasis(basis))
        case .commit(let oid):
            .commit(oid: oid)
        case .ref(let name, let basis):
            .ref(name: name, basis: ipcComparisonBasis(basis))
        }
    }

    private func ipcComparisonBasis(
        _ basis: WorkspaceReviewComparisonBasis
    ) -> IPCBridgeReviewComparisonBasis {
        switch basis {
        case .commonCommit:
            .commonCommit
        case .branchTip:
            .branchTip
        }
    }

    private func ipcComparisonBaseRole(
        _ role: BridgeReviewComparisonBaseRole
    ) -> IPCBridgeReviewComparisonBaseRole {
        switch role {
        case .commonCommit:
            .commonCommit
        case .selectedTarget:
            .selectedTarget
        }
    }

    private func ipcReviewItemSummaries(
        _ package: BridgeReviewPackage
    ) throws -> [IPCBridgeReviewItemSummary] {
        try package.orderedItemIds.map { itemId in
            guard let descriptor = package.itemsById[itemId],
                let displayPath = descriptor.headPath ?? descriptor.basePath
            else {
                throw BridgeIPCProjectionError(reason: .validationRejected)
            }
            return IPCBridgeReviewItemSummary(
                itemId: descriptor.itemId,
                displayPath: displayPath,
                itemKind: descriptor.itemKind.rawValue,
                changeKind: descriptor.changeKind.rawValue,
                collapsed: descriptor.collapsed
            )
        }
    }

    private func ipcContentHandle(_ handle: BridgeContentHandle) -> IPCBridgeContentHandleSummary {
        IPCBridgeContentHandleSummary(
            identity: IPCBridgeContentHandleIdentity(
                handleId: handle.handleId,
                itemId: handle.itemId,
                role: handle.role.rawValue,
                reviewGeneration: handle.reviewGeneration.rawValue
            ),
            presentation: IPCBridgeContentHandlePresentation(
                mimeType: handle.mimeType,
                language: handle.language
            ),
            size: IPCBridgeContentHandleSize(
                sizeBytes: handle.sizeBytes,
                isBinary: handle.isBinary
            )
        )
    }

    private nonisolated func javaScriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw BridgeIPCProjectionError(reason: .validationRejected)
        }
        return literal
    }

    private nonisolated func javaScriptLiteral<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw BridgeIPCProjectionError(reason: .validationRejected)
        }
        return literal
    }
}
