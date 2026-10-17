import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import Testing
import WebKit

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test("retained Comment replay waits for source continuity before W4 installs puts and tombstones")
    // Keep native sealing, W4 installation, and late producer cleanup in one ordered real-path proof.
    // swiftlint:disable:next function_body_length
    func retainedCommentReplayWaitsForPublisherHandoffThroughW4() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "bridge-comment-replay-continuity")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)

        let readGate = CommentRevisionReplayCatalogReadGate()
        let replayDiagnostics = CommentRevisionReplayDiagnosticRecorder()
        let repository = try makeCommentRevisionReplayRepository()
        let annotationStore = WorktreeAnnotationServiceActor(
            repositoryAccess: CommentRevisionReplayRepositoryAccess(
                repository: repository,
                diagnostics: replayDiagnostics,
                beforeCatalogRangeRead: { try await readGate.holdNextRead() }
            )
        )
        let traceRecorder = BridgeProductWebKitCarrierTraceRecorder()
        let controller = makeController(
            repoURL: repositoryURL,
            traceRecorder: traceRecorder,
            worktreeAnnotationStore: annotationStore
        )

        let run = try await BridgeProductWebKitCarrierTestSupport.withHostedController(
            controller,
            frame: NSRect(x: 0, y: 0, width: 640, height: 720)
        ) { hostedController in
            hostedController.loadApp()
            await WebPageEventWaits.waitForNavigationToFinish(hostedController.page)
            let reviewIsReady = try await waitForReviewReady(controller: controller, page: hostedController.page)
            #expect(reviewIsReady)
            try await selectReviewItemPath(hostedController.page, path: "tracked.txt")
            let provider = try #require(controller.productSchemeProvider)
            let coordinator = await provider.metadataCoordinator
            let producerObservations = await coordinator.annotationSource.observeProducerEvents()
            let producerObservationReader = CommentRevisionReplayProducerObservationReader(
                producerObservations.events
            )

            let seed = try await reviewCommentSeed(controller: controller, repositoryURL: repositoryURL)

            let rootBody = "RR4 retained root comment"
            let deletedDraftBody = "RR4 draft removed during restart"
            let replayReplyBody = "RR4 reply delivered after replay"

            let rootDraft = try await annotationStore.createRootDraft(
                rootDraftProps(
                    seed: seed,
                    admission: .implicitOrSingle,
                    body: rootBody,
                    editToken: "rr4-root-editor",
                    now: 10
                )
            )
            let rootMessage = try #require(rootDraft.threads.first?.messages.first)
            let savedRoot = try await annotationStore.saveDraft(
                .init(
                    sessionID: rootDraft.session.id,
                    messageID: rootMessage.id,
                    editToken: "rr4-root-editor",
                    expectedMessageRevision: rootMessage.semanticRevision,
                    expectedDraftRevision: try #require(rootMessage.draft?.draftRevision),
                    now: Date(timeIntervalSince1970: 11)
                )
            )
            let rootThread = try #require(savedRoot.threads.first?.thread)

            let deletionDraft = try await annotationStore.createRootDraft(
                rootDraftProps(
                    seed: seed,
                    admission: .selected(savedRoot.session.id),
                    body: deletedDraftBody,
                    editToken: "rr4-delete-editor",
                    now: 12
                )
            )
            let originalThreadIDs = Set(savedRoot.threads.map(\.thread.id))
            let deletedThread = try #require(
                deletionDraft.threads.first { !originalThreadIDs.contains($0.thread.id) }
            )
            let deletedMessage = try #require(deletedThread.messages.first)

            let annotationsButtonIsEnabled = try await waitForEnabledAnnotationsButton(hostedController.page)
            #expect(annotationsButtonIsEnabled)
            try await clickAccessibleButton(hostedController.page, label: "Annotations")
            try await selectAllCommentReplayShareScope(hostedController.page)
            let pageDiagnostics = try await CommentRevisionReplayPageDiagnosticObserver.start(
                page: hostedController.page,
                diagnostics: replayDiagnostics
            )
            do {
                let initialAnnotationBodies = try await waitForAnnotationBodies(
                    hostedController.page,
                    // isCurrentSaved excludes unsaved drafts; prove draft keys in the catalog seal below.
                    required: [rootBody]
                )
                #expect(initialAnnotationBodies.contains(rootBody))
            } catch {
                await pageDiagnostics.stop()
                throw error
            }
            await pageDiagnostics.stop()

            let installation = try #require(await controller.productSessionOwner.activeInstallation)
            let reviewView = try await requireCommentReplayReviewView(
                coordinator: coordinator, session: installation.session
            )
            let subscriptionID = reviewView.subscriptionID
            let viewHandle = reviewView.handle
            let acceptedScope = try #require(
                await installation.session.acceptedViewScope(subscriptionId: subscriptionID)
            )
            #expect(acceptedScope.handle == viewHandle)
            let seededKeys: Set<WorktreeAnnotationCatalogKey> = [
                .session(savedRoot.session.id), .thread(rootThread.id), .message(rootMessage.id),
                .thread(deletedThread.thread.id), .message(deletedMessage.id),
            ]
            let initialCapture = try await producerObservationReader.firstSealedCapture(
                handle: viewHandle, containing: seededKeys
            )
            let initialProducerID = initialCapture.producerID
            let initialBatch = initialCapture.batch
            #expect(
                seededKeys.isSubset(
                    of: Set(initialBatch.puts.map { WorktreeAnnotationCatalogKey(entry: $0.entry) })))
            #expect(initialBatch.targetRevision > 0)

            let resolvedCursorDetail = try await annotationStore.setThreadResolution(
                .init(
                    sessionID: savedRoot.session.id,
                    threadID: rootThread.id,
                    resolution: .resolved,
                    expectedThreadRevision: rootThread.semanticRevision,
                    now: Date(timeIntervalSince1970: 13)
                )
            )
            let threadIsResolved = try await waitForAnnotationThreadResolution(
                hostedController.page,
                threadID: rootThread.id,
                resolution: "resolved"
            )
            #expect(threadIsResolved)
            let resolvedBatch = try requireSealedBatch(
                await producerObservationReader.nextSealedBatch(
                    handle: viewHandle,
                    producerID: initialProducerID,
                    matching: { batch in
                        batch.puts.contains { record in
                            guard case .session(let session) = record.entry else { return false }
                            return session.sessionID == savedRoot.session.id
                                && session.semanticRevision >= resolvedCursorDetail.session.semanticRevision
                        }
                    }
                ),
                milestone: "catalog invalidation after resolving the root thread"
            )
            #expect(resolvedBatch.targetRevision > initialBatch.targetRevision)

            let resolvedThread = try #require(
                resolvedCursorDetail.threads.first { $0.thread.id == rootThread.id }?.thread
            )
            let reopenedCursorDetail = try await annotationStore.setThreadResolution(
                .init(
                    sessionID: resolvedCursorDetail.session.id,
                    threadID: resolvedThread.id,
                    resolution: .open,
                    expectedThreadRevision: resolvedThread.semanticRevision,
                    now: Date(timeIntervalSince1970: 14)
                )
            )
            let threadIsOpen = try await waitForAnnotationThreadResolution(
                hostedController.page,
                threadID: rootThread.id,
                resolution: "open"
            )
            #expect(threadIsOpen)
            let cursorAdvancedBatch = try requireSealedBatch(
                await producerObservationReader.nextSealedBatch(
                    handle: viewHandle,
                    producerID: initialProducerID,
                    matching: { batch in
                        batch.puts.contains { record in
                            guard case .session(let session) = record.entry else { return false }
                            return session.sessionID == savedRoot.session.id
                                && session.semanticRevision >= reopenedCursorDetail.session.semanticRevision
                        }
                    }
                ),
                milestone: "catalog invalidation after reopening the root thread"
            )
            #expect(cursorAdvancedBatch.targetRevision > resolvedBatch.targetRevision)
            var previousCursor = cursorAdvancedBatch.targetRevision

            try await installCommentReplayPageObserver(
                hostedController.page,
                changedBody: replayReplyBody
            )
            let pageInstallationWaiter = Task { @MainActor in
                try? await hostedController.page.callJavaScript(
                    "return await globalThis.__rr4CommentReplayInstallPromise;"
                ) as? String
            }

            await readGate.armReads(readerCount: reviewView.liveCatalogViewCount)
            let replyDraft = try await annotationStore.createReplyDraft(
                .init(
                    sessionID: savedRoot.session.id,
                    threadID: rootThread.id,
                    expectedThreadRevision: try #require(
                        reopenedCursorDetail.threads.first { $0.thread.id == rootThread.id }?.thread
                            .semanticRevision
                    ),
                    body: replayReplyBody,
                    editToken: "rr4-replay-reply-editor",
                    now: Date(timeIntervalSince1970: 15)
                )
            )
            let replyMessage = try #require(
                replyDraft.threads.first { $0.thread.id == rootThread.id }?.messages.last
            )
            let afterReplySave = try await annotationStore.saveDraft(
                .init(
                    sessionID: replyDraft.session.id,
                    messageID: replyMessage.id,
                    editToken: "rr4-replay-reply-editor",
                    expectedMessageRevision: replyMessage.semanticRevision,
                    expectedDraftRevision: try #require(replyMessage.draft?.draftRevision),
                    now: Date(timeIntervalSince1970: 16)
                )
            )
            let currentDeletedMessage = try #require(
                afterReplySave.threads.first { $0.thread.id == deletedThread.thread.id }?
                    .messages.first { $0.id == deletedMessage.id }
            )
            _ = try await annotationStore.revertDraft(
                .init(
                    sessionID: afterReplySave.session.id,
                    messageID: currentDeletedMessage.id,
                    editToken: "rr4-delete-editor",
                    expectedMessageRevision: currentDeletedMessage.semanticRevision,
                    expectedDraftRevision: try #require(currentDeletedMessage.draft?.draftRevision),
                    now: Date(timeIntervalSince1970: 17)
                )
            )
            #expect(try await readGate.waitUntilCatalogReadersAreHeld() == reviewView.liveCatalogViewCount)

            let suspension = try #require(controller.applyBridgePaneActivity(.loadedHidden))
            #expect(try await readGate.waitUntilCancellationObserved() == reviewView.liveCatalogViewCount)
            let foregroundTransition = controller.applyBridgePaneActivity(.foreground)
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity == .foreground)
            let foregroundAdmission = try #require(provider.refreshWorkAdmissionSource.acquire())
            #expect(foregroundAdmission.withValidAdmission({ true }) == true)

            await coordinator.replaySubscriptionsForInstalledStream()
            let replayProducerID = try #require(
                await producerObservationReader.nextOpenedProducerID(handle: viewHandle)
            )
            let handoffDecision = try #require(
                await producerObservationReader.nextHandoffDecision(
                    handle: viewHandle,
                    producerID: replayProducerID
                )
            )
            // Every preceding seal has been observed before this correlated handoff decision.
            previousCursor = try #require(
                await producerObservationReader.lastSealedBatch(handle: viewHandle, producerID: initialProducerID)
            ).targetRevision
            let replayProducerInstalledBeforeP0Retired: Bool
            let preRetirementReplayBatch: BridgeProductCommentCatalogBatch?
            switch handoffDecision {
            case .waitingForRetirement(let predecessorID):
                replayProducerInstalledBeforeP0Retired = false
                preRetirementReplayBatch = nil
                #expect(predecessorID == initialProducerID)
            case .publisherInstalled:
                replayProducerInstalledBeforeP0Retired = true
                #expect(Bool(false), "Replay installed P1 before P0 captured continuity")
                let preRetirementOutcome = await producerObservationReader.nextSealedBatch(
                    handle: viewHandle,
                    producerID: replayProducerID
                )
                switch preRetirementOutcome {
                case .sealed(let batch):
                    preRetirementReplayBatch = batch
                case .finished(let reason):
                    #expect(Bool(false), "P1 finished before its pre-retirement seal: \(reason)")
                    await readGate.releaseHeldRead()
                    await suspension.value
                    if let foregroundTransition { await foregroundTransition.value }
                    _ = try? await hostedController.page.callJavaScript(
                        "globalThis.__rr4ResolveCommentReplayInstall('producer-finished');"
                    )
                    _ = await pageInstallationWaiter.value
                    await coordinator.suspendForegroundWork()
                    await coordinator.annotationSource.stopObservingProducerEvents(
                        id: producerObservations.id
                    )
                    return
                case .streamEnded:
                    #expect(Bool(false), "Producer observation stream ended before P1's pre-retirement seal")
                    await readGate.releaseHeldRead()
                    await suspension.value
                    if let foregroundTransition { await foregroundTransition.value }
                    _ = try? await hostedController.page.callJavaScript(
                        "globalThis.__rr4ResolveCommentReplayInstall('producer-stream-ended');"
                    )
                    _ = await pageInstallationWaiter.value
                    await coordinator.suspendForegroundWork()
                    await coordinator.annotationSource.stopObservingProducerEvents(
                        id: producerObservations.id
                    )
                    return
                }
            }

            await readGate.releaseHeldRead()
            await suspension.value
            if let foregroundTransition { await foregroundTransition.value }

            let replayBatch: BridgeProductCommentCatalogBatch
            if replayProducerInstalledBeforeP0Retired {
                replayBatch = try #require(
                    preRetirementReplayBatch,
                    "P1's pre-retirement seal was observed before P0 retired"
                )
            } else {
                let replayOutcome = await producerObservationReader.nextSealedBatch(
                    handle: viewHandle,
                    producerID: replayProducerID
                )
                switch replayOutcome {
                case .sealed(let batch):
                    replayBatch = batch
                case .finished(let reason):
                    #expect(Bool(false), "Replayed producer finished before native sealing: \(reason)")
                    _ = try? await hostedController.page.callJavaScript(
                        "globalThis.__rr4ResolveCommentReplayInstall('producer-finished');"
                    )
                    _ = await pageInstallationWaiter.value
                    await coordinator.suspendForegroundWork()
                    await coordinator.annotationSource.stopObservingProducerEvents(
                        id: producerObservations.id
                    )
                    return
                case .streamEnded:
                    #expect(Bool(false), "Producer observation stream ended before replay sealing")
                    _ = try? await hostedController.page.callJavaScript(
                        "globalThis.__rr4ResolveCommentReplayInstall('producer-stream-ended');"
                    )
                    _ = await pageInstallationWaiter.value
                    await coordinator.suspendForegroundWork()
                    await coordinator.annotationSource.stopObservingProducerEvents(
                        id: producerObservations.id
                    )
                    return
                }
            }
            let replayPutKey = WorktreeAnnotationCatalogKey.message(replyMessage.id).recordKey
            let expectedDeletedKeys: Set<String> = [
                WorktreeAnnotationCatalogKey.thread(deletedThread.thread.id).recordKey,
                WorktreeAnnotationCatalogKey.message(deletedMessage.id).recordKey,
            ]
            let replayPutKeys = Set(replayBatch.puts.map(\.recordKey))
            let replayDeletedKeys = Set(replayBatch.deletes.map { $0.key.recordKey })
            let sealedBatchContinuesInstalledCursor =
                replayBatch.baseRevision == previousCursor
                && replayBatch.targetRevision > previousCursor
                && replayBatch.puts.allSatisfy { $0.revision > previousCursor }
                && replayBatch.deletes.allSatisfy { $0.revision > previousCursor }
                && replayPutKeys.contains(replayPutKey)
                && replayDeletedKeys == expectedDeletedKeys
            #expect(
                sealedBatchContinuesInstalledCursor,
                "Native sealing did not preserve the W4 cursor, changed put, and deletion tombstones"
            )
            if !sealedBatchContinuesInstalledCursor {
                _ = try? await hostedController.page.callJavaScript(
                    "globalThis.__rr4ResolveCommentReplayInstall('stale-sealed-batch');"
                )
            }
            let pageInstallationResult = await pageInstallationWaiter.value
            #expect(
                pageInstallationResult == "installed",
                "Replay page installation ended with \(pageInstallationResult ?? "nil")"
            )
            guard sealedBatchContinuesInstalledCursor else {
                await coordinator.suspendForegroundWork()
                await coordinator.annotationSource.stopObservingProducerEvents(id: producerObservations.id)
                return
            }
            let replayedScope = try #require(
                await installation.session.acceptedViewScope(subscriptionId: subscriptionID)
            )
            #expect(replayedScope.handle == viewHandle)

            await coordinator.annotationSource.releaseProducerBatchScope(
                handle: viewHandle,
                producerID: initialProducerID
            )
            let postCleanupBody = "P1 route survived P0 cleanup"
            // Creation returns the whole session; identify the new thread by ID rather than the first row.
            let priorThreadIDs = Set(afterReplySave.threads.map(\.thread.id))
            let postCleanupDraft = try await annotationStore.createRootDraft(
                rootDraftProps(
                    seed: seed,
                    admission: .selected(savedRoot.session.id),
                    body: postCleanupBody,
                    editToken: "rr4-post-cleanup-editor",
                    now: 18
                )
            )
            let postCleanupThread = try #require(
                postCleanupDraft.threads.first { !priorThreadIDs.contains($0.thread.id) }
            )
            let postCleanupMessage = try #require(postCleanupThread.messages.first)
            _ = try await annotationStore.saveDraft(
                .init(
                    sessionID: postCleanupDraft.session.id,
                    messageID: postCleanupMessage.id,
                    editToken: "rr4-post-cleanup-editor",
                    expectedMessageRevision: postCleanupMessage.semanticRevision,
                    expectedDraftRevision: try #require(postCleanupMessage.draft?.draftRevision),
                    now: Date(timeIntervalSince1970: 19)
                )
            )
            let postCleanupBatch = try requireSealedBatch(
                await producerObservationReader.nextSealedBatch(
                    handle: viewHandle,
                    producerID: replayProducerID,
                    matching: { batch in
                        batch.puts.contains {
                            $0.recordKey == WorktreeAnnotationCatalogKey.message(postCleanupMessage.id).recordKey
                        }
                    }
                ),
                milestone: "catalog invalidation after P0 cleanup"
            )
            #expect(postCleanupBatch.targetRevision > replayBatch.targetRevision)
            #expect(
                postCleanupBatch.puts.contains {
                    $0.recordKey == WorktreeAnnotationCatalogKey.message(postCleanupMessage.id).recordKey
                }
            )
            let finalAnnotationBodies = try await waitForAnnotationBodies(
                hostedController.page,
                required: [rootBody, replayReplyBody, postCleanupBody]
            )
            #expect([rootBody, replayReplyBody, postCleanupBody].allSatisfy(finalAnnotationBodies.contains))
            await coordinator.suspendForegroundWork()
            await coordinator.annotationSource.stopObservingProducerEvents(id: producerObservations.id)
        }
        #expect(run.teardownSnapshot.hasZeroResidue)
    }
}

@MainActor
private func waitForReviewReady(controller: BridgePaneController, page: WebPage) async throws -> Bool {
    let observedReadiness = try await WebPageEventWaits.waitForDocumentValue(
        page,
        reader: """
            const shell = document.querySelector('[data-testid="review-viewer-shell"]');
            return shell?.getAttribute('data-selected-content-state') === 'ready' ? true : null;
            """
    )
    guard let admission = controller.productAdmissionGate.acquire(),
        let publication = controller.reviewPublicationCoordinator.committedPublicationForReplay(
            productAdmission: admission
        ), !publication.package.itemsById.isEmpty
    else {
        throw WorktreeAnnotationServiceError.unavailable
    }
    return try #require(observedReadiness as? Bool)
}

@MainActor
private func waitForEnabledAnnotationsButton(_ page: WebPage) async throws -> Bool {
    let observedEnablement = try await WebPageEventWaits.waitForDocumentValue(
        page,
        reader: """
            const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
            const button = Array.from(activeHost?.querySelectorAll('button') ?? []).find(
              candidate =>
                candidate.getAttribute('aria-label') === 'Annotations' ||
                candidate.textContent?.trim() === 'Annotations'
            );
            return button instanceof HTMLButtonElement && !button.disabled ? true : null;
            """
    )
    return try #require(observedEnablement as? Bool)
}

@MainActor
private func clickAccessibleButton(_ page: WebPage, label: String) async throws {
    let clicked =
        try await page.callJavaScript(
            """
            const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
            const button = Array.from(activeHost?.querySelectorAll('button') ?? []).find(
              candidate =>
                candidate.getAttribute('aria-label') === label ||
                candidate.textContent?.trim() === label
            );
            if (!(button instanceof HTMLButtonElement) || button.disabled) return false;
            button.click();
            return true;
            """,
            arguments: ["label": label]
        ) as? Bool ?? false
    _ = try #require(clicked)
}

@MainActor
private func waitForAnnotationThreadResolution(
    _ page: WebPage,
    threadID: WorktreeAnnotationThreadID,
    resolution: String
) async throws -> Bool {
    let observedResolution = try await WebPageEventWaits.waitForOpenShadowRootValue(
        page,
        reader: """
            const findThread = root => {
              const thread = root.querySelector(`[data-annotation-thread-id="${threadID}"]`);
              if (thread !== null) return thread;
              for (const element of root.querySelectorAll('*')) {
                if (element.shadowRoot !== null) {
                  const nested = findThread(element.shadowRoot);
                  if (nested !== null) return nested;
                }
              }
              return null;
            };
            const thread = findThread(document);
            if (thread?.getAttribute('data-annotation-resolution') === resolution) return true;
            const shareThread = Array.from(document.querySelectorAll(`[data-thread-id="${threadID}"]`))
              .find(candidate => candidate.getClientRects().length !== 0);
            if (shareThread === undefined) return null;
            const isResolved = shareThread.querySelector('[aria-label="Resolved conversation"]') !== null;
            return isResolved === (resolution === 'resolved') ? true : null;
            """,
        arguments: [
            "threadID": threadID.rawValue.uuidString.lowercased(),
            "resolution": resolution,
        ]
    )
    return try #require(observedResolution as? Bool)
}

@MainActor
private func installCommentReplayPageObserver(
    _ page: WebPage,
    changedBody: String
) async throws {
    _ = try await page.callJavaScript(
        """
        const collect = root => {
          let values = Array.from(root.querySelectorAll('[data-testid="worktree-annotation-message"]'))
            .map(element => element.textContent ?? '');
          for (const element of root.querySelectorAll('*')) {
            if (element.shadowRoot !== null) values = values.concat(collect(element.shadowRoot));
          }
          return values.join('\\n');
        };
        let observer = null;
        let resolved = false;
        globalThis.__rr4ResolveCommentReplayInstall = value => {
          if (resolved) return;
          resolved = true;
          observer?.disconnect();
          globalThis.__rr4CommentReplayInstallResolve(value);
        };
        globalThis.__rr4CommentReplayInstallPromise = new Promise(resolve => {
          globalThis.__rr4CommentReplayInstallResolve = resolve;
          const inspect = () => {
            const bodies = collect(document);
            if (bodies.includes(changedBody)) {
              globalThis.__rr4ResolveCommentReplayInstall('installed');
            }
          };
          observer = new MutationObserver(inspect);
          observer.observe(document.documentElement, {
            attributes: true, characterData: true, childList: true, subtree: true
          });
          inspect();
        });
        return true;
        """,
        arguments: ["changedBody": changedBody]
    )
}
