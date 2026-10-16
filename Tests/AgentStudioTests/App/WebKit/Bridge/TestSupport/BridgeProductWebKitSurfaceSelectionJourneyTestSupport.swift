import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

struct BridgeProductWebKitSurfaceSelectionState: Decodable, Equatable, Sendable {
    let activeMode: String?
    let fileDisplayItemCount: Int?
    let fileDisplaySourceId: String?
    let fileDisplayStatus: String?
    let fileHostRetained: Bool
    let fileProjectedRowCount: Int?
    let fileTotalRowCount: Int?
    let reviewContentState: String?
    let reviewHostRetained: Bool
    let reviewSelectedItemId: String?
    let reviewSelectedPath: String?
}

struct BridgeProductWebKitSurfaceSelectionReceipt: Equatable, Sendable {
    let paneSessionId: String
    let requestId: String
    let bindingRevision: Int
    let surface: BridgeProductSurface
    let workerInstanceId: String

    init(_ request: BridgePaneSurfaceSelectionRequest) {
        paneSessionId = request.paneSessionId
        requestId = request.requestId
        bindingRevision = request.bindingRevision
        surface = request.surface
        workerInstanceId = request.workerInstanceId
    }
}

struct BridgeProductWebKitSurfaceSelectionJourneyProof: Sendable {
    let fileStateAfterFirstSelection: BridgeProductWebKitSurfaceSelectionState
    let finalFileState: BridgeProductWebKitSurfaceSelectionState
    let finalMetadataSequence: Int
    let finalWorkerInstanceId: String?
    let initialMetadataSequence: Int
    let initialReviewState: BridgeProductWebKitSurfaceSelectionState
    let initialWorkerInstanceId: String?
    let receipts: [BridgeProductWebKitSurfaceSelectionReceipt]
    let reviewStateAfterReturn: BridgeProductWebKitSurfaceSelectionState
    let teardownHasZeroResidue: Bool
}

@MainActor
enum BridgeProductWebKitSurfaceJourneyTestSupport {
    static func run() async throws -> BridgeProductWebKitSurfaceSelectionJourneyProof {
        let repoURL = try await FilesystemTestGitRepo.create(
            named: "bridge-product-native-surface-selection-webkit"
        )
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)

        let controller = makeController(repoURL: repoURL)
        let run = try await BridgeProductWebKitCarrierTestSupport.withHostedController(
            controller
        ) { hostedController in
            hostedController.loadApp()
            await WebPageEventWaits.waitForNavigationToFinish(hostedController.page)
            try await establishHostIdentity(hostedController.page)
            let initialReviewState = try await requireReadyReview(hostedController)
            let initialNative = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(
                hostedController
            )

            let fileReceipt = try await requestSurface(.file, controller: hostedController)
            let fileStateAfterFirstSelection = try await requireReadyFile(hostedController.page)

            let reviewReceipt = try await requestSurface(.review, controller: hostedController)
            let reviewStateAfterReturn = try await requireReviewState(
                initialReviewState,
                activeMode: "review",
                page: hostedController.page
            )

            let finalFileReceipt = try await requestSurface(.file, controller: hostedController)
            let finalFileState = try await requireRetainedState(
                fileState: fileStateAfterFirstSelection,
                reviewState: initialReviewState,
                page: hostedController.page
            )
            let finalNative = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(
                hostedController
            )

            return BridgeProductWebKitSurfaceSelectionJourneyProof(
                fileStateAfterFirstSelection: fileStateAfterFirstSelection,
                finalFileState: finalFileState,
                finalMetadataSequence: finalNative.nextMetadataStreamSequence,
                finalWorkerInstanceId: finalNative.workerInstanceId,
                initialMetadataSequence: initialNative.nextMetadataStreamSequence,
                initialReviewState: initialReviewState,
                initialWorkerInstanceId: initialNative.workerInstanceId,
                receipts: [fileReceipt, reviewReceipt, finalFileReceipt],
                reviewStateAfterReturn: reviewStateAfterReturn,
                teardownHasZeroResidue: false
            )
        }

        return BridgeProductWebKitSurfaceSelectionJourneyProof(
            fileStateAfterFirstSelection: run.value.fileStateAfterFirstSelection,
            finalFileState: run.value.finalFileState,
            finalMetadataSequence: run.value.finalMetadataSequence,
            finalWorkerInstanceId: run.value.finalWorkerInstanceId,
            initialMetadataSequence: run.value.initialMetadataSequence,
            initialReviewState: run.value.initialReviewState,
            initialWorkerInstanceId: run.value.initialWorkerInstanceId,
            receipts: run.value.receipts,
            reviewStateAfterReturn: run.value.reviewStateAfterReturn,
            teardownHasZeroResidue: run.teardownSnapshot.hasZeroResidue
        )
    }

    static func assertProof(_ proof: BridgeProductWebKitSurfaceSelectionJourneyProof) {
        #expect(proof.initialWorkerInstanceId?.isEmpty == false)
        #expect(proof.finalWorkerInstanceId == proof.initialWorkerInstanceId)
        #expect(proof.finalMetadataSequence >= proof.initialMetadataSequence + 3)
        #expect(proof.receipts.map(\.surface) == [.file, .review, .file])
        #expect(Set(proof.receipts.map(\.requestId)).count == 3)
        #expect(proof.receipts.allSatisfy { !$0.requestId.isEmpty })
        #expect(Set(proof.receipts.map(\.paneSessionId)).count == 1)
        #expect(proof.receipts.allSatisfy { !$0.paneSessionId.isEmpty })
        let bindingRevisions = proof.receipts.map(\.bindingRevision)
        #expect(
            zip(bindingRevisions, bindingRevisions.dropFirst()).allSatisfy {
                $0.0 < $0.1
            }
        )
        #expect(
            proof.receipts.allSatisfy {
                $0.workerInstanceId == proof.initialWorkerInstanceId
            }
        )
        #expect(proof.initialReviewState.activeMode == "review")
        #expect(proof.initialReviewState.reviewContentState == "ready")
        #expect(proof.initialReviewState.reviewSelectedItemId?.isEmpty == false)
        #expect(proof.initialReviewState.reviewSelectedPath?.isEmpty == false)
        #expect(proof.fileStateAfterFirstSelection.activeMode == "file")
        #expect(proof.fileStateAfterFirstSelection.fileDisplayStatus == "ready")
        #expect(proof.fileStateAfterFirstSelection.fileDisplaySourceId?.isEmpty == false)
        #expect((proof.fileStateAfterFirstSelection.fileDisplayItemCount ?? 0) > 0)
        #expect((proof.fileStateAfterFirstSelection.fileProjectedRowCount ?? 0) > 0)
        #expect(proof.reviewStateAfterReturn.activeMode == "review")
        #expect(
            proof.reviewStateAfterReturn.reviewContentState
                == proof.initialReviewState.reviewContentState
        )
        #expect(
            proof.reviewStateAfterReturn.reviewSelectedItemId
                == proof.initialReviewState.reviewSelectedItemId
        )
        #expect(
            proof.reviewStateAfterReturn.reviewSelectedPath
                == proof.initialReviewState.reviewSelectedPath
        )
        #expect(proof.finalFileState.activeMode == "file")
        #expect(proof.finalFileState.fileHostRetained)
        #expect(proof.finalFileState.reviewHostRetained)
        #expect(
            proof.finalFileState.fileDisplaySourceId
                == proof.fileStateAfterFirstSelection.fileDisplaySourceId
        )
        #expect(
            proof.finalFileState.fileProjectedRowCount
                == proof.fileStateAfterFirstSelection.fileProjectedRowCount
        )
        #expect(
            proof.finalFileState.fileProjectedRowCount
                == proof.finalFileState.fileTotalRowCount
        )
        #expect(
            proof.finalFileState.reviewSelectedItemId
                == proof.initialReviewState.reviewSelectedItemId
        )
        #expect(
            proof.finalFileState.reviewSelectedPath
                == proof.initialReviewState.reviewSelectedPath
        )
        #expect(proof.teardownHasZeroResidue)
    }

    private static func requestSurface(
        _ surface: BridgeProductSurface,
        controller: BridgePaneController
    ) async throws -> BridgeProductWebKitSurfaceSelectionReceipt {
        let previousRevision =
            controller.surfaceSelectionAuthority.diagnosticSnapshot.lastAcceptedRequest?
            .bindingRevision ?? 0
        guard controller.requestViewerSurface(surface) else {
            throw JourneyError.conditionFailed("native \(surface) request was not admitted")
        }

        let acceptedRequest: BridgePaneSurfaceSelectionRequest =
            try await BridgePaneControllerEventWaits.waitForValue {
                let snapshot = controller.surfaceSelectionAuthority.diagnosticSnapshot
                guard let lastAcceptedRequest = snapshot.lastAcceptedRequest,
                    snapshot.currentRequest == nil,
                    lastAcceptedRequest.surface == surface,
                    lastAcceptedRequest.bindingRevision > previousRevision
                else { return nil }
                return lastAcceptedRequest
            }
        try await requireActiveMode(surface, page: controller.page)
        return BridgeProductWebKitSurfaceSelectionReceipt(acceptedRequest)
    }

    private static func establishHostIdentity(_ page: WebPage) async throws {
        try await WebPageEventWaits.waitForDocumentSelector(
            page,
            "[data-testid=\"bridge-viewer-mode-host-file\"]"
        )
        try await WebPageEventWaits.waitForDocumentSelector(
            page,
            "[data-testid=\"bridge-viewer-mode-host-review\"]"
        )
        let established =
            try await page.callJavaScript(
                """
                const fileHost = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
                const reviewHost = document.querySelector('[data-testid="bridge-viewer-mode-host-review"]');
                if (!(fileHost instanceof HTMLElement) || !(reviewHost instanceof HTMLElement)) return false;
                globalThis.__bridgeHostedSurfaceSelectionHosts = { fileHost, reviewHost };
                return true;
                """
            ) as? Bool
        guard established == true else {
            throw JourneyError.conditionFailed("retained File and Review hosts were not mounted")
        }
    }

    private static func requireActiveMode(
        _ surface: BridgeProductSurface,
        page: WebPage
    ) async throws {
        let expectedMode = surface == .file ? "file" : "review"
        _ = try await awaitState(
            page,
            where: "return state.activeMode === expectedMode;",
            arguments: ["expectedMode": expectedMode]
        )
    }

    private static func requireReadyReview(
        _ controller: BridgePaneController
    ) async throws -> BridgeProductWebKitSurfaceSelectionState {
        let observed = try await awaitState(
            controller.page,
            where: """
                return state.activeMode === 'review'
                  && state.reviewContentState === 'ready'
                  && Boolean(state.reviewSelectedItemId)
                  && Boolean(state.reviewSelectedPath)
                  && state.fileHostRetained
                  && state.reviewHostRetained;
                """
        )
        let native = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(controller)
        guard native.lifecycle == "active" else {
            throw JourneyError.conditionFailed("real-git Review native session was not active")
        }
        return observed
    }

    private static func requireReadyFile(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitSurfaceSelectionState {
        try await awaitState(
            page,
            where: """
                return state.activeMode === 'file'
                  && state.fileDisplayStatus === 'ready'
                  && Boolean(state.fileDisplaySourceId)
                  && state.fileDisplayItemCount > 0
                  && state.fileProjectedRowCount > 0
                  && state.fileProjectedRowCount === state.fileTotalRowCount
                  && state.fileHostRetained
                  && state.reviewHostRetained;
                """
        )
    }

    /// Asserts, with one read, that Review state survived the surface switches.
    ///
    /// The barrier is already behind us: `requestSurface` awaited the native
    /// selection receipt and then the retained host's activation in the DOM. This is
    /// a RETENTION claim, so it is read exactly once. Polling it until it holds
    /// would accept a Review host that lost its selection and rebuilt it — the very
    /// regression the journey exists to catch.
    private static func requireReviewState(
        _ expected: BridgeProductWebKitSurfaceSelectionState,
        activeMode: String,
        page: WebPage
    ) async throws -> BridgeProductWebKitSurfaceSelectionState {
        guard let observed = try await state(page) else {
            throw JourneyError.conditionFailed("Review state could not be read after surface switch")
        }
        guard observed.activeMode == activeMode,
            observed.fileHostRetained,
            observed.reviewHostRetained,
            observed.reviewContentState == expected.reviewContentState,
            observed.reviewSelectedItemId == expected.reviewSelectedItemId,
            observed.reviewSelectedPath == expected.reviewSelectedPath
        else {
            throw JourneyError.conditionFailed(
                "Review state changed during native surface switches; "
                    + "expected=\(expected) observed=\(observed)"
            )
        }
        return observed
    }

    /// Asserts, with one read, that BOTH retained hosts kept their state across the
    /// final switch back to File. Same retention reasoning as `requireReviewState`.
    private static func requireRetainedState(
        fileState: BridgeProductWebKitSurfaceSelectionState,
        reviewState: BridgeProductWebKitSurfaceSelectionState,
        page: WebPage
    ) async throws -> BridgeProductWebKitSurfaceSelectionState {
        guard let observed = try await state(page) else {
            throw JourneyError.conditionFailed("retained state could not be read after surface switch")
        }
        guard observed.activeMode == "file",
            observed.fileHostRetained,
            observed.reviewHostRetained,
            observed.fileDisplayStatus == fileState.fileDisplayStatus,
            observed.fileDisplaySourceId == fileState.fileDisplaySourceId,
            observed.fileDisplayItemCount == fileState.fileDisplayItemCount,
            observed.fileProjectedRowCount == fileState.fileProjectedRowCount,
            observed.fileTotalRowCount == fileState.fileTotalRowCount,
            observed.reviewContentState == reviewState.reviewContentState,
            observed.reviewSelectedItemId == reviewState.reviewSelectedItemId,
            observed.reviewSelectedPath == reviewState.reviewSelectedPath
        else {
            throw JourneyError.conditionFailed(
                "retained File or Review state changed; observed=\(observed)"
            )
        }
        return observed
    }

    /// JavaScript function body returning the journey's whole observable surface
    /// state as a plain object.
    ///
    /// Every field is derived from the DOM — element presence, attributes, and one
    /// `textContent` — and from a JS global captured once by `establishHostIdentity`.
    /// That is what lets `awaitState` re-read it from a `MutationObserver`: each
    /// field can only change through a mutation the observer sees.
    private static let stateReaderBody = """
        const fileHost = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
        const reviewHost = document.querySelector('[data-testid="bridge-viewer-mode-host-review"]');
        const retained = globalThis.__bridgeHostedSurfaceSelectionHosts;
        const fileShell = fileHost?.querySelector('[data-testid="bridge-file-viewer-shell"]');
        const reviewShell = reviewHost?.querySelector('[data-testid="review-viewer-shell"]');
        const reviewPanel = reviewHost?.querySelector('[data-testid="bridge-code-view-panel"]');
        const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
        const filterCountText = fileHost?.querySelector(
          '[data-testid="worktree-file-filter-count"]'
        )?.textContent ?? '';
        const filterCounts = filterCountText.split('/').map((value) => Number(value));
        const projectedRowCount = Number(fileShell?.getAttribute('data-file-display-tree-row-count'));
        return {
          activeMode: activeHost?.getAttribute('data-bridge-viewer-mode-host') ?? null,
          fileDisplayItemCount: Number.isSafeInteger(
            Number(fileShell?.getAttribute('data-file-display-item-count'))
          ) ? Number(fileShell?.getAttribute('data-file-display-item-count')) : null,
          fileDisplaySourceId: fileShell?.getAttribute('data-file-display-source-id') ?? null,
          fileDisplayStatus: fileShell?.getAttribute('data-file-display-status') ?? null,
          fileHostRetained: retained?.fileHost === fileHost,
          fileProjectedRowCount: Number.isSafeInteger(projectedRowCount)
            ? projectedRowCount
            : null,
          fileTotalRowCount: filterCounts.length === 2 && Number.isSafeInteger(filterCounts[1])
            ? filterCounts[1]
            : null,
          reviewContentState: reviewShell?.getAttribute('data-selected-content-state') ?? null,
          reviewHostRetained: retained?.reviewHost === reviewHost,
          reviewSelectedItemId: reviewPanel?.getAttribute('data-selected-item-id') ?? null,
          reviewSelectedPath: reviewShell?.getAttribute('data-selected-display-path') ?? null
        };
        """

    /// Suspends until the surface state satisfies `predicate`, then answers with it.
    ///
    /// `predicate` is a JavaScript function body over an in-scope `state` constant.
    /// The wait is driven by DOM mutations, never by a clock.
    private static func awaitState(
        _ page: WebPage,
        where predicate: String,
        arguments: [String: Any] = [:]
    ) async throws -> BridgeProductWebKitSurfaceSelectionState {
        let encoded = try await WebPageEventWaits.waitForDocumentValue(
            page,
            reader: """
                const state = (() => { \(stateReaderBody) })();
                const matches = (() => { \(predicate) })();
                return matches ? JSON.stringify(state) : null;
                """,
            arguments: arguments
        )
        guard let encoded = encoded as? String,
            let data = encoded.data(using: .utf8)
        else {
            throw JourneyError.conditionFailed("surface state reader did not answer with JSON")
        }
        return try JSONDecoder().decode(BridgeProductWebKitSurfaceSelectionState.self, from: data)
    }

    /// Reads the surface state once, with no wait of any kind.
    ///
    /// Used where a preceding wait has already established the barrier and the
    /// claim is that the state is a particular value AT that point — a retention
    /// claim is weakened, not strengthened, by re-sampling until it happens to hold.
    private static func state(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitSurfaceSelectionState? {
        let encoded = try await page.callJavaScript(
            """
            const readSurfaceState = () => { \(stateReaderBody) };
            return JSON.stringify(readSurfaceState());
            """
        )
        guard let encoded = encoded as? String,
            let data = encoded.data(using: .utf8)
        else { return nil }
        return try JSONDecoder().decode(BridgeProductWebKitSurfaceSelectionState.self, from: data)
    }

    private static func makeController(repoURL: URL) -> BridgePaneController {
        let paneId = UUIDv7.generate()
        let gitReadContext = makeBridgeGitReadContext(rootURL: repoURL)
        return BridgePaneController(
            paneId: paneId,
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: repoURL.path,
                    baseline: .localDefaultBranch(branchName: "main")
                )
            ),
            appRootURL: testBridgeAppRootURL(),
            metadata: PaneMetadata(
                paneId: PaneId(existingUUID: paneId),
                contentType: .diff,
                launchDirectory: repoURL,
                title: "Bridge Native Surface Selection",
                facets: PaneContextFacets(
                    repoId: UUIDv7.generate(),
                    worktreeId: UUIDv7.generate(),
                    worktreeName: "bridge-native-surface-selection",
                    cwd: repoURL
                )
            ),
            reviewSourceProvider: BridgeReviewSourceProviderFactory.gitProvider(
                repositoryPath: repoURL,
                gitReadContext: gitReadContext
            ),
            gitReadContext: gitReadContext,
            worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator(),
            gitWorkingTreeStatusProvider: AgentStudioGitWorkingTreeStatusProvider(
                physicalGate: AgentStudioGitStatusPhysicalGate()
            ),
            telemetryRuntimePolicy: .live,
            telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: []),
            initialPaneActivity: .foreground
        )
    }

    private enum JourneyError: Error {
        case conditionFailed(String)
    }
}
