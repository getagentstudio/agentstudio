import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import WebKit

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

struct BridgeProductPackagedShareJourneyProof: Sendable {
    let clipboardBytes: Data
    let exportedJSON: Data
    let fileHistoryCount: Int
    let fileUnavailableCommentsExcluded: Bool
    let hostWidth: Double
    let reviewHistoryCount: Int
    let reviewPendingCount: Int
}

extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test("packaged File and Review Share performs exact App effects and durable unhandle")
    func packagedFileAndReviewSharePerformsExactEffectsAndUnhandle() async throws {
        let proof = try await BridgeProductPackagedShareJourneyTestSupport.run(self)

        #expect(proof.reviewPendingCount == 1)
        #expect(proof.reviewHistoryCount == 1)
        #expect(proof.fileUnavailableCommentsExcluded)
        #expect(proof.fileHistoryCount == 2)
        #expect(proof.clipboardBytes.contains(Data("Packaged Share comment".utf8)))
        #expect(proof.exportedJSON.contains(Data("Packaged Share comment".utf8)))
        #expect(proof.hostWidth == 640)
    }
}

@MainActor
enum BridgeProductPackagedShareJourneyTestSupport {
    private struct JourneyHarness {
        let controller: BridgePaneController
        let exportedJSONURL: URL
        let pasteboard: NSPasteboard
        let repositoryURL: URL
        let stateRoot: URL
        let store: WorktreeAnnotationServiceActor

        func destroy() {
            FilesystemTestGitRepo.destroy(repositoryURL)
            try? FileManager.default.removeItem(at: stateRoot)
        }
    }

    private struct ShareDOMSnapshot: Decodable {
        let allCount: Int
        let animationStates: [String]
        let copyButtonText: String?
        let historyCount: Int
        let inspectionText: String?
        let pendingCount: Int
        let otherSavedCommentsVisible: Bool
        let shareEndingStyle: Bool
        let shareOpen: Bool
        let shareVisible: Bool
        let shareErrorText: String?
        let toastText: String?
        let visibilityState: String
    }

    static func run(
        _ testOwner: WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests
    ) async throws -> BridgeProductPackagedShareJourneyProof {
        let harness = try await makeJourneyHarness(testOwner)
        defer { harness.destroy() }

        return try await BridgeProductWebKitCarrierTestSupport.withHostedController(
            harness.controller,
            frame: NSRect(x: 0, y: 0, width: 640, height: 720)
        ) { hostedController in
            hostedController.loadApp()
            await WebPageEventWaits.waitForNavigationToFinish(hostedController.page)
            try await requirePackagedReviewReady(hostedController)
            try await disableAnimationsForHiddenPackagedCarrier(hostedController.page)
            _ = try await seedReviewAnnotation(
                controller: hostedController,
                repositoryURL: harness.repositoryURL,
                store: harness.store
            )
            try await requireEnabledButton(hostedController.page, label: "Annotations")
            try await clickButton(hostedController.page, label: "Annotations")
            _ = try await requireShareSnapshot(
                hostedController.page,
                stage: "review-pending",
                where: "return snapshot.shareVisible && snapshot.pendingCount === 1;"
            )
            try await clickButton(hostedController.page, label: "Copy Markdown")
            let dismissal = try await requireOutputDismissed(
                hostedController,
                stage: "review-copy-dismiss"
            )
            #expect(dismissal == "closed")
            let clipboardBytes = try #require(harness.pasteboard.data(forType: .string))

            try await clickButton(hostedController.page, label: "Annotations")
            _ = try await requireShareSnapshot(
                hostedController.page,
                stage: "review-history",
                where: "return snapshot.shareVisible && snapshot.historyCount === 1 && snapshot.pendingCount === 0;"
            )
            try await clickButton(hostedController.page, label: "History (1)")
            try await clickButton(hostedController.page, label: "Inspect output attempt 1")
            let savedOutputText = try #require(String(data: clipboardBytes, encoding: .utf8))
            _ = try await requireShareSnapshot(
                hostedController.page,
                stage: "review-inspect-output",
                where: "return snapshot.inspectionText === expectedText;",
                arguments: ["expectedText": savedOutputText]
            )
            try await clickButton(
                hostedController.page,
                label: "Mark as not handled",
                withinTestID: "worktree-annotation-share-shelf"
            )
            let reviewAfterUnhandle = try await requireShareSnapshot(
                hostedController.page,
                stage: "review-unhandle",
                where: "return snapshot.shareOpen && snapshot.shareVisible && snapshot.pendingCount === 1;"
            )
            try await clickButton(hostedController.page, label: "Close Annotations")

            let fileProof = try await performFileExport(
                controller: hostedController,
                exportedJSONURL: harness.exportedJSONURL
            )
            return BridgeProductPackagedShareJourneyProof(
                clipboardBytes: clipboardBytes,
                exportedJSON: fileProof.exportedJSON,
                fileHistoryCount: fileProof.history.historyCount,
                fileUnavailableCommentsExcluded: !fileProof.beforeExport.otherSavedCommentsVisible,
                hostWidth: 640,
                reviewHistoryCount: reviewAfterUnhandle.historyCount,
                reviewPendingCount: reviewAfterUnhandle.pendingCount
            )
        }.value
    }

    private static func disableAnimationsForHiddenPackagedCarrier(_ page: WebPage) async throws {
        _ = try await page.callJavaScript(
            """
            globalThis.BASE_UI_ANIMATIONS_DISABLED = true;
            """
        )
    }

    private static func makeJourneyHarness(
        _ testOwner: WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests
    ) async throws -> JourneyHarness {
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "bridge-packaged-share-webkit")
        let stateRoot = FileManager.default.temporaryDirectory.appending(
            path: "bridge-packaged-share-state-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        let exportedJSONURL = stateRoot.appending(path: "review-comments.json")
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let alternateFileURL = repositoryURL.appending(path: "alternate.txt")
        try "alternate initial\n".write(to: alternateFileURL, atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["add", "alternate.txt"])
        try await FilesystemTestGitRepo.runGit(
            at: repositoryURL,
            args: ["commit", "-m", "Add alternate packaged Share file"]
        )
        try "alternate initial\nalternate updated\n".write(
            to: alternateFileURL,
            atomically: true,
            encoding: .utf8
        )

        let datastore = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: stateRoot.appending(path: "core.sqlite"),
            localDatabaseURL: stateRoot.appending(path: "local.sqlite")
        ).makeDatastore()
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            throw WorktreeAnnotationServiceError.unavailable
        }
        let store = WorktreeAnnotationServiceActor(
            sqliteAdapter: .init(workspaceID: UUIDv7.generate(), datastore: datastore)
        )
        let pasteboard = NSPasteboard(
            name: .init("agentstudio.packaged-share.\(UUIDv7.generate().uuidString)")
        )
        let outputCoordinator = WorktreeAnnotationOutputCoordinatorActor(
            store: store,
            effect: WorktreeAnnotationOutputEffects(
                pasteboard: pasteboard,
                folderPreference: InMemoryWorktreeAnnotationOutputFolderPreference(
                    folderURL: exportedJSONURL.deletingLastPathComponent()
                )
            )
        )
        let traceRecorder = BridgeProductWebKitCarrierTraceRecorder()
        let controller = testOwner.makeController(
            repoURL: repositoryURL,
            traceRecorder: traceRecorder,
            worktreeAnnotationStore: store,
            worktreeAnnotationOutputCoordinator: outputCoordinator
        )
        return JourneyHarness(
            controller: controller,
            exportedJSONURL: exportedJSONURL,
            pasteboard: pasteboard,
            repositoryURL: repositoryURL,
            stateRoot: stateRoot,
            store: store
        )
    }

    private static func performFileExport(
        controller: BridgePaneController,
        exportedJSONURL: URL
    ) async throws -> (
        beforeExport: ShareDOMSnapshot,
        exportedJSON: Data,
        history: ShareDOMSnapshot
    ) {
        guard await BridgeProductWebKitCarrierTestSupport.activateFileMode(controller.page) else {
            throw PackagedShareJourneyError.fileModeUnavailable
        }
        _ = try await WebPageEventWaits.waitForOpenShadowRootValue(
            controller.page,
            reader: """
                const selector = `button[data-type="item"][data-item-type="file"][data-item-path="${CSS.escape(path)}"]`;
                return findInOpenShadowRoots(document, selector) === null ? null : path;
                """,
            arguments: ["path": "alternate.txt"]
        )
        let selectedDifferentFile = await BridgeProductWebKitCarrierTestSupport.selectFilePath(
            controller.page,
            path: "alternate.txt"
        )
        guard selectedDifferentFile else {
            throw PackagedShareJourneyError.fileSelectionUnavailable
        }
        _ = try await WebPageEventWaits.waitForOpenShadowRootValue(
            controller.page,
            reader: """
                const fileHost = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
                return fileHost !== null && readOpenShadowRootText(fileHost).includes('alternate updated')
                  ? 'alternate updated' : null;
                """
        )
        try await requireEnabledButton(controller.page, label: "Annotations")
        try await clickButton(controller.page, label: "Annotations")
        try await clickButtonWithPrefix(controller.page, prefix: "All")
        let beforeExport = try await requireShareSnapshot(
            controller.page,
            stage: "file-other",
            where: "return snapshot.shareVisible && !snapshot.otherSavedCommentsVisible && snapshot.allCount === 1;"
        )
        try await clickButton(controller.page, label: "Export JSON")
        _ = try await requireShareSnapshot(
            controller.page,
            stage: "file-export-saved",
            where: "return snapshot.shareVisible && snapshot.historyCount === 2;"
        )
        let exportedFiles = try FileManager.default.contentsOfDirectory(
            at: exportedJSONURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("AgentStudio Review Comments ") && $0.pathExtension == "json" }
        guard exportedFiles.count == 1, let savedURL = exportedFiles.first else {
            throw PackagedShareJourneyError.exportMissing
        }
        let exportedJSON = try Data(contentsOf: savedURL)

        let history = try await requireShareSnapshot(
            controller.page,
            stage: "file-history",
            where: "return snapshot.shareVisible && snapshot.historyCount === 2;"
        )
        return (beforeExport, exportedJSON, history)
    }

    private static func requirePackagedReviewReady(_ controller: BridgePaneController) async throws {
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
                return reviewShell?.getAttribute('data-selected-content-state') === 'ready' ? true : null;
                """
        )
        guard let productAdmission = controller.productAdmissionGate.acquire(),
            let publication = controller.reviewPublicationCoordinator
                .committedPublicationForReplay(productAdmission: productAdmission),
            !publication.package.itemsById.isEmpty
        else { throw PackagedShareJourneyError.reviewUnavailable }
    }

    private static func seedReviewAnnotation(
        controller: BridgePaneController,
        repositoryURL: URL,
        store: WorktreeAnnotationServiceActor
    ) async throws -> String {
        let productAdmission = try #require(controller.productAdmissionGate.acquire())
        let publication = try #require(
            controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )
        let fingerprint = try await WorktreeAnnotationSourceCapture.reviewRefresh(
            identity: BridgeProductReviewAnnotationPublicationIdentity(
                packageId: publication.package.packageId,
                publicationId: publication.publicationId,
                reviewGeneration: publication.package.reviewGeneration.rawValue,
                revision: publication.package.revision,
                sourceIdentity: publication.package.query.queryId
            ),
            publicationCoordinator: controller.reviewPublicationCoordinator,
            contentLoaderCache: controller.reviewContentLoaderCache,
            requirements: [],
            productAdmission: productAdmission
        ).fingerprint
        let item = try #require(
            publication.package.itemsById.values.first {
                $0.headPath == "tracked.txt" && $0.contentRoles.head != nil
            }
        )
        let path = try #require(item.headPath)
        let handle = try #require(item.contentRoles.head)
        let source = try String(
            contentsOf: repositoryURL.appending(path: path),
            encoding: .utf8
        )
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let firstLine = sourceLines.first.map(String.init) ?? ""
        let secondLine = sourceLines.dropFirst().first.map(String.init)
        var detail = try await store.createRootDraft(
            .init(
                admission: .implicitOrSingle,
                repositoryID: fingerprint.repositoryID,
                worktreeID: fingerprint.worktreeID,
                sourceFingerprint: fingerprint,
                origin: .located(
                    .init(
                        repositoryRelativePath: path,
                        startLine: 1,
                        endLine: 1,
                        sourceRole: .reviewHead,
                        diffSide: .additions,
                        sourceIdentity: handle.handleId,
                        selectedExcerpt: firstLine,
                        contextBefore: nil,
                        contextAfter: secondLine
                    )
                ),
                body: "## Packaged Share comment\n\nPreserve exact output bytes.",
                editToken: "packaged-share-editor",
                now: Date(timeIntervalSince1970: 1)
            )
        )
        let message = try #require(detail.threads.first?.messages.first)
        let draft = try #require(message.draft)
        detail = try await store.saveDraft(
            .init(
                sessionID: detail.session.id,
                messageID: message.id,
                editToken: try #require(draft.activeEditToken),
                expectedMessageRevision: message.semanticRevision,
                expectedDraftRevision: draft.draftRevision,
                now: Date(timeIntervalSince1970: 2)
            )
        )
        _ = detail
        return path
    }

    private static func requireEnabledButton(_ page: WebPage, label: String) async throws {
        _ = try await WebPageEventWaits.waitForDocumentValue(
            page,
            reader: """
                const buttonLabel = String(label);
                const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
                const button = Array.from(activeHost?.querySelectorAll('button') ?? []).find(
                  candidate =>
                    candidate.getAttribute('aria-label') === buttonLabel ||
                    candidate.textContent?.trim() === buttonLabel
                );
                return button instanceof HTMLButtonElement && !button.disabled ? true : null;
                """,
            arguments: ["label": label]
        )
    }

    private static func requireOutputDismissed(
        _ controller: BridgePaneController,
        stage: String
    ) async throws -> String {
        let observed = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
                const share = activeHost?.querySelector('[data-testid="worktree-annotation-share-mode"]');
                if (share === null) return 'closed';
                const error = share?.querySelector('[role="alert"]')?.textContent;
                return error === null || error === undefined ? null : error;
                """
        )
        guard let observed = observed as? String, observed == "closed" else {
            let installation = await controller.productSessionOwner.activeInstallation
            let sessionDiagnostic = await installation?.session.diagnosticSnapshot
            let retainedOutcomes = await installation?.session.diagnosticRetainedOperationOutcomes()
            let sessionSnapshot = await installation?.session.snapshot
            let ownerDiagnostic = await controller.productSessionOwner.snapshot()
            throw PackagedShareJourneyError.shareDidNotConverge(
                stage: stage,
                observed: "workerError=\(String(describing: observed)); "
                    + "retainedResults=\(sessionDiagnostic?.retainedOperationResultCount ?? -1); "
                    + "retainedOutcomes=\(String(describing: retainedOutcomes)); "
                    + "activeExecutions=\(ownerDiagnostic.activeOperationExecutionCount); "
                    + "pendingControl=\(ownerDiagnostic.pendingControlCount); "
                    + "nextSequence=\(sessionSnapshot?.controlReplay.nextExpectedRequestSequence ?? -1); "
                    + "inFlightSequence=\(String(describing: sessionSnapshot?.controlReplay.inFlightRequestSequence))"
            )
        }
        return observed
    }

    private static func clickButton(
        _ page: WebPage,
        label: String,
        withinTestID: String? = nil
    ) async throws {
        let clicked =
            try await page.callJavaScript(
                """
                const buttonLabel = String(label);
                const containerTestID = String(withinTestID);
                const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
                const container = containerTestID.length === 0
                  ? activeHost
                  : activeHost?.querySelector(`[data-testid="${containerTestID}"]`);
                const button = Array.from(container?.querySelectorAll('button') ?? []).find(
                  candidate =>
                    candidate.getAttribute('aria-label') === buttonLabel ||
                    candidate.textContent?.trim() === buttonLabel
                );
                if (!(button instanceof HTMLButtonElement) || button.disabled) return false;
                button.click();
                return true;
                """,
                arguments: ["label": label, "withinTestID": withinTestID ?? ""]
            ) as? Bool
        guard clicked == true else { throw PackagedShareJourneyError.missingButton(label) }
    }

    private static func clickButtonWithPrefix(_ page: WebPage, prefix: String) async throws {
        let clicked =
            try await page.callJavaScript(
                """
                const buttonPrefix = String(prefix);
                const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
                const button = Array.from(activeHost?.querySelectorAll('button') ?? []).find(
                  candidate => candidate.textContent?.trim().startsWith(buttonPrefix)
                );
                if (!(button instanceof HTMLButtonElement) || button.disabled) return false;
                button.click();
                return true;
                """,
                arguments: ["prefix": prefix]
            ) as? Bool
        guard clicked == true else { throw PackagedShareJourneyError.missingButton(prefix) }
    }

    private static func requireShareSnapshot(
        _ page: WebPage,
        stage: String,
        where predicate: String,
        arguments: [String: Any] = [:]
    ) async throws -> ShareDOMSnapshot {
        let encoded = try await WebPageEventWaits.waitForDocumentValue(
            page,
            reader: """
                const snapshot = (() => { \(shareSnapshotReaderBody) })();
                const matches = (() => { \(predicate) })();
                return matches ? JSON.stringify(snapshot) : null;
                """,
            arguments: arguments
        )
        guard let string = encoded as? String else {
            throw PackagedShareJourneyError.shareDidNotConverge(
                stage: stage,
                observed: String(describing: encoded)
            )
        }
        return try JSONDecoder().decode(ShareDOMSnapshot.self, from: Data(string.utf8))
    }

    private static let shareSnapshotReaderBody = """
        const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
        const buttons = Array.from(activeHost?.querySelectorAll('button') ?? []);
        const textForPrefix = prefix => buttons.find(
          button => button.textContent?.trim().startsWith(prefix)
        )?.textContent?.trim() ?? '';
        const integerIn = value => Number(value.match(/\\d+/)?.[0] ?? '0');
        return {
          allCount: integerIn(textForPrefix('All')),
          animationStates: Array.from(
            activeHost?.querySelector('[data-testid="worktree-annotation-share-shelf"]')
              ?.getAnimations({ subtree: true }) ?? []
          ).map(animation => `${animation.playState}:${animation.pending}`),
          copyButtonText: buttons.find(button => button.getAttribute('aria-label') === 'Copy Markdown')
            ?.textContent?.trim() ?? null,
          historyCount: integerIn(textForPrefix('History (')),
          inspectionText: activeHost?.querySelector(
            '[data-testid="annotation-output-inspection"] pre'
          )?.textContent ?? null,
          pendingCount: integerIn(textForPrefix('Pending')),
          otherSavedCommentsVisible:
            (activeHost?.querySelector('[aria-label="Other saved comments"]') ?? null) !== null,
          shareEndingStyle:
            activeHost?.querySelector('[data-testid="worktree-annotation-share-shelf"]')
              ?.hasAttribute('data-ending-style') === true,
          shareOpen:
            activeHost?.querySelector('[data-testid="worktree-annotation-share-shelf"]')
              ?.hasAttribute('data-open') === true,
          shareVisible:
            (activeHost?.querySelector('[data-testid="worktree-annotation-share-mode"]') ?? null) !== null,
          shareErrorText: activeHost?.querySelector('[data-testid="worktree-annotation-share-mode"] [role="alert"]')
            ?.textContent ?? null,
          toastText: document.querySelector('[data-sonner-toast]')?.textContent ?? null,
          visibilityState: document.visibilityState
        };
        """

}

private enum PackagedShareJourneyError: Error {
    case exportMissing
    case fileModeUnavailable
    case fileSelectionUnavailable
    case missingButton(String)
    case reviewUnavailable
    case shareDidNotConverge(stage: String, observed: String)
}
