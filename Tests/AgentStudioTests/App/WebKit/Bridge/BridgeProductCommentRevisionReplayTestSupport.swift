import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing
import WebKit

@testable import AgentStudio
@testable import AgentStudioBridge

struct ReviewCommentSeed {
    let fingerprint: WorktreeAnnotationSourceFingerprint
    let origin: WorktreeAnnotationThreadOrigin
}

@MainActor
func reviewCommentSeed(
    controller: BridgePaneController,
    repositoryURL: URL
) async throws -> ReviewCommentSeed {
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
    let source = try String(contentsOf: repositoryURL.appending(path: path), encoding: .utf8)
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let firstLine = lines.first.map(String.init) ?? ""
    let addedLine = try #require(lines.dropFirst().first.map(String.init))
    return .init(
        fingerprint: fingerprint,
        origin: .located(
            .init(
                repositoryRelativePath: path,
                startLine: 2,
                endLine: 2,
                sourceRole: .reviewHead,
                diffSide: .additions,
                sourceIdentity: handle.handleId,
                selectedExcerpt: addedLine,
                contextBefore: firstLine,
                contextAfter: nil
            )
        )
    )
}

func rootDraftProps(
    seed: ReviewCommentSeed,
    admission: WorktreeAnnotationSQLiteRepository.SessionAdmission,
    body: String,
    editToken: String,
    now: TimeInterval
) -> WorktreeAnnotationSQLiteRepository.CreateRootDraftProps {
    .init(
        admission: admission,
        repositoryID: seed.fingerprint.repositoryID,
        worktreeID: seed.fingerprint.worktreeID,
        sourceFingerprint: seed.fingerprint,
        origin: seed.origin,
        body: body,
        editToken: editToken,
        now: Date(timeIntervalSince1970: now)
    )
}

func makeCommentRevisionReplayRepository() throws -> WorktreeAnnotationSQLiteRepository {
    let repository = WorktreeAnnotationSQLiteRepository(
        databaseWriter: try SQLiteDatabaseFactory.makeInMemoryQueue()
    )
    try WorkspaceLocalMigrations.migrate(repository.databaseWriter)
    return repository
}

actor CommentRevisionReplayRepositoryAccess: WorktreeAnnotationRepositoryAccess {
    private let repository: WorktreeAnnotationSQLiteRepository
    private let diagnostics: CommentRevisionReplayDiagnosticRecorder
    private let beforeCatalogRangeRead: (@Sendable () async throws -> Void)?

    init(
        repository: WorktreeAnnotationSQLiteRepository,
        diagnostics: CommentRevisionReplayDiagnosticRecorder,
        beforeCatalogRangeRead: (@Sendable () async throws -> Void)? = nil
    ) {
        self.repository = repository
        self.diagnostics = diagnostics
        self.beforeCatalogRangeRead = beforeCatalogRangeRead
    }

    func discoverSessions(worktreeID: String) async throws -> [WorktreeAnnotationSession] {
        try repository.discoverSessions(worktreeID: worktreeID)
    }

    func fetchSessionDetail(sessionID: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        try repository.fetchSessionDetail(sessionID: sessionID)
    }

    func fetchProjectionSnapshot(
        worktreeID: String,
        demandedSessionIDs: [WorktreeAnnotationSessionID]
    ) async throws -> WorktreeAnnotationRepositoryProjectionSnapshot {
        await diagnostics.recordProjectionDemand(demandedSessionIDs)
        let snapshot = try repository.fetchProjectionSnapshot(
            worktreeID: worktreeID,
            demandedSessionIDs: demandedSessionIDs
        )
        await diagnostics.recordProjectionRows(snapshot)
        return snapshot
    }

    func fetchCatalogCapture(worktreeID: String) async throws -> WorktreeAnnotationCatalogCapture {
        let capture = try repository.fetchCatalogCapture(worktreeID: worktreeID)
        await diagnostics.recordCatalog(capture)
        return capture
    }

    func fetchCatalogRange(
        worktreeID: String,
        range: WorktreeAnnotationCatalogRange
    ) async throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry] {
        try await beforeCatalogRangeRead?()
        return try repository.fetchCatalogRange(worktreeID: worktreeID, range: range)
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.createRootDraft(props)
    }

    func flushDraft(_ props: WorktreeAnnotationSQLiteRepository.FlushDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try repository.flushDraft(props)
    }

    func saveDraft(_ props: WorktreeAnnotationSQLiteRepository.SaveDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.saveDraft(props)
    }

    func revertDraft(_ props: WorktreeAnnotationSQLiteRepository.RevertDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try repository.revertDraft(props)
    }

    func acquireEditToken(_ props: WorktreeAnnotationSQLiteRepository.AcquireEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.acquireEditToken(props)
    }

    func releaseEditToken(_ props: WorktreeAnnotationSQLiteRepository.ReleaseEditTokenProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.releaseEditToken(props)
    }

    func createReplyDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateReplyDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.createReplyDraft(props)
    }

    func setThreadResolution(_ props: WorktreeAnnotationSQLiteRepository.SetThreadResolutionProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.setThreadResolution(props)
    }

    func setSessionLifecycle(_ props: WorktreeAnnotationSQLiteRepository.SetSessionLifecycleProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.setSessionLifecycle(props)
    }

    func setSourceRelationship(_ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try repository.setSourceRelationship(props)
    }

    func prepareOutput(_ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    {
        try repository.prepareOutput(props)
    }

    func inspectOutputAttempt(attemptID: WorktreeAnnotationOutputAttemptID) async throws
        -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    {
        try repository.inspectOutputAttempt(attemptID: attemptID)
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try repository.cancelOutputAttempt(attemptID: attemptID, now: now)
    }

    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try repository.finalizeOutputAttempt(
            attemptID: attemptID,
            eventKind: eventKind,
            destinationPath: destinationPath,
            now: now
        )
    }

    func markPreparedOutputAttemptsUnknown(now: Date) async throws
        -> WorktreeAnnotationCommittedMutation<Int>
    {
        try repository.markPreparedOutputAttemptsUnknown(now: now)
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws
        -> WorktreeAnnotationRecoveryProvenance?
    {
        try repository.fetchUnacknowledgedRecoveryProvenance()
    }

    func acknowledgeRecoveryProvenance(
        id: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        try repository.acknowledgeRecoveryProvenance(id: id, acknowledgedAt: acknowledgedAt)
    }
}

actor CommentRevisionReplayDiagnosticRecorder {
    private var catalogSummary = "unobserved"
    private var demandedSessions = "unobserved"
    private var projectionRows = "unobserved"
    private var pageSnapshot = "unobserved"
    private var lastLoggedSnapshot: String?
    private var loggedSnapshotCount = 0

    func recordCatalog(_ capture: WorktreeAnnotationCatalogCapture) {
        let sessionRevisions = capture.sessions
            .map { "\($0.sessionID.rawValue.uuidString.lowercased()):\($0.semanticRevision)" }
            .joined(separator: ",")
        catalogSummary =
            "sessions=\(capture.sessions.count)[\(sessionRevisions)] "
            + "threads=\(capture.threads.count) messages=\(capture.messages.count)"
        logSnapshotIfChanged()
    }

    func recordProjectionDemand(_ demandedSessionIDs: [WorktreeAnnotationSessionID]) {
        demandedSessions =
            demandedSessionIDs
            .map { $0.rawValue.uuidString.lowercased() }
            .joined(separator: ",")
        logSnapshotIfChanged()
    }

    func recordProjectionRows(_ snapshot: WorktreeAnnotationRepositoryProjectionSnapshot) {
        let threads = snapshot.details.flatMap(\.threads)
        let messages = threads.flatMap(\.messages)
        let draftCount = messages.filter { $0.draft != nil }.count
        projectionRows =
            "sessions=\(snapshot.sessions.count) threads=\(threads.count) "
            + "messages=\(messages.count) drafts=\(draftCount)"
        logSnapshotIfChanged()
    }

    func recordPageSnapshot(_ snapshot: String) {
        pageSnapshot = snapshot
        logSnapshotIfChanged()
    }

    private func logSnapshotIfChanged() {
        let snapshot =
            "catalog={\(catalogSummary)} demand={\(demandedSessions)} "
            + "projection={\(projectionRows)} page={\(pageSnapshot)}"
        guard snapshot != lastLoggedSnapshot, loggedSnapshotCount < 32 else { return }
        lastLoggedSnapshot = snapshot
        loggedSnapshotCount += 1
        print("RR4_WEBKIT_DIAGNOSTIC[\(loggedSnapshotCount)] \(snapshot)")
    }
}

@MainActor
final class CommentRevisionReplayPageDiagnosticObserver {
    private struct PageSnapshots: Decodable {
        let snapshots: [String]
    }

    private let page: WebPage
    private let diagnostics: CommentRevisionReplayDiagnosticRecorder
    private var snapshotsRead = 0
    private var titleObservationTask: Task<Void, Never>?
    private var titleChangesContinuation: AsyncStream<Void>.Continuation?

    private init(page: WebPage, diagnostics: CommentRevisionReplayDiagnosticRecorder) {
        self.page = page
        self.diagnostics = diagnostics
    }

    static func start(
        page: WebPage,
        diagnostics: CommentRevisionReplayDiagnosticRecorder
    ) async throws -> CommentRevisionReplayPageDiagnosticObserver {
        let observer = CommentRevisionReplayPageDiagnosticObserver(
            page: page,
            diagnostics: diagnostics
        )
        _ = try await page.callJavaScript(installScript)
        observer.startObservingTitleChanges()
        return observer
    }

    func stop() async {
        titleChangesContinuation?.finish()
        titleObservationTask?.cancel()
        _ = try? await page.callJavaScript(
            """
            globalThis.__rr4CommentPageDiagnostic?.disconnect();
            document.title = 'RR4_PAGE_DIAGNOSTIC_STOP';
            return true;
            """
        )
        await titleObservationTask?.value
    }

    private func startObservingTitleChanges() {
        let (titleChanges, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        titleChangesContinuation = continuation
        let streamContinuation = continuation
        titleObservationTask = Task { @MainActor [self, page] in
            @MainActor func observeTitleChange() {
                withObservationTracking {
                    _ = page.title
                } onChange: {
                    _ = streamContinuation.yield(())
                }
            }

            observeTitleChange()
            await self.readQueuedPageSnapshots()
            for await _ in titleChanges {
                if Task.isCancelled { return }
                observeTitleChange()
                await self.readQueuedPageSnapshots()
            }
            streamContinuation.finish()
        }
    }

    private func readQueuedPageSnapshots() async {
        guard
            let encodedSnapshots = try? await page.callJavaScript(
                "return JSON.stringify(globalThis.__rr4CommentPageDiagnostic ?? { snapshots: [] });"
            ) as? String,
            let data = encodedSnapshots.data(using: .utf8),
            let pageSnapshots = try? JSONDecoder().decode(PageSnapshots.self, from: data)
        else {
            return
        }
        for snapshot in pageSnapshots.snapshots.dropFirst(snapshotsRead) {
            await diagnostics.recordPageSnapshot(snapshot)
        }
        snapshotsRead = pageSnapshots.snapshots.count
    }

    private static let installScript = """
        return (() => {
          const maximumDistinctSnapshots = 16;
          const snapshots = [];
          const observers = new Map();
          let previousSnapshot = null;
          let disconnected = false;
          const collectMatching = (root, selector) => {
            let matches = Array.from(root.querySelectorAll(selector));
            for (const element of root.querySelectorAll('*')) {
              if (element.shadowRoot !== null) matches = matches.concat(collectMatching(element.shadowRoot, selector));
            }
            return matches;
          };
          const readSnapshot = () => JSON.stringify({
            messageTexts: collectMatching(document, '[data-testid="worktree-annotation-message"]')
              .slice(0, 8).map(element => (element.textContent ?? '').trim().slice(0, 400)),
            reviewSelectedPath: document.querySelector('[data-testid="review-viewer-shell"]')
              ?.getAttribute('data-selected-display-path') ?? null,
            shareDrawerText: collectMatching(document, '[data-testid="worktree-annotation-share-mode"]')
              .slice(0, 1).map(element => (element.textContent ?? '').trim().slice(0, 800)),
            threads: collectMatching(document, '[data-testid="worktree-annotation-thread"]')
              .slice(0, 8).map(element => ({
                id: element.getAttribute('data-annotation-thread-id'),
                placement: element.getAttribute('data-annotation-placement'),
                resolution: element.getAttribute('data-annotation-resolution'),
              })),
          });
          const disconnect = () => {
            disconnected = true;
            for (const observer of observers.values()) observer.disconnect();
            observers.clear();
          };
          const publishIfChanged = () => {
            if (disconnected) return;
            observeRoots(document.documentElement);
            const snapshot = readSnapshot();
            if (snapshot === previousSnapshot || snapshots.length >= maximumDistinctSnapshots) return;
            previousSnapshot = snapshot;
            snapshots.push(snapshot);
            document.title = `RR4_PAGE_DIAGNOSTIC:${snapshots.length}`;
            if (snapshots.length === maximumDistinctSnapshots) disconnect();
          };
          const observeRoots = root => {
            if (!observers.has(root)) {
              const observer = new MutationObserver(publishIfChanged);
              observer.observe(root, { attributes: true, characterData: true, childList: true, subtree: true });
              observers.set(root, observer);
            }
            for (const element of root.querySelectorAll('*')) {
              if (element.shadowRoot !== null) observeRoots(element.shadowRoot);
            }
          };
          globalThis.__rr4CommentPageDiagnostic = { snapshots, disconnect };
          publishIfChanged();
          return true;
        })();
        """
}

@MainActor
func waitForAnnotationBodies(_ page: WebPage, required: [String]) async throws -> String {
    let observedBodies = try await WebPageEventWaits.waitForOpenShadowRootValue(
        page,
        reader: """
            const collect = root => {
              let values = Array.from(root.querySelectorAll('[data-testid="worktree-annotation-message"]'))
                .map(element => element.textContent ?? '');
              for (const element of root.querySelectorAll('*')) {
                if (element.shadowRoot !== null) values = values.concat(collect(element.shadowRoot));
              }
              return values.join('\\n');
            };
            const body = collect(document);
            return required.every(value => body.includes(value)) ? body : null;
            """,
        arguments: ["required": required],
        milestone: "retained Review annotation bodies rendered",
        lastObservation: "return globalThis.__rr4CommentPageDiagnostic?.snapshots.at(-1) ?? 'no page snapshot';"
    )
    return try #require(observedBodies as? String)
}

actor CommentRevisionReplayCatalogReadGate {
    private var remainingReadsToHold = 0
    private var heldReads: [HeldStep<Void>] = []
    private let allReadersHeld = HeldStep<Int>("every live comment catalog reader is held")

    func armReads(readerCount: Int) {
        precondition(readerCount > 0 && heldReads.isEmpty)
        remainingReadsToHold = readerCount
    }

    func holdNextRead() async throws {
        guard remainingReadsToHold > 0 else { return }
        remainingReadsToHold -= 1
        let heldRead = HeldStep<Void>(
            "comment replay catalog reader \(heldReads.count + 1)",
            cancellation: .holdThroughCancellation
        )
        heldReads.append(heldRead)
        if remainingReadsToHold == 0 {
            allReadersHeld.release()
            try await allReadersHeld.arrive(heldReads.count)
        }
        try await heldRead.arrive(())
        try Task.checkCancellation()
    }

    func waitUntilCatalogReadersAreHeld() async throws -> Int {
        try await allReadersHeld.firstArrival()
    }

    func waitUntilCancellationObserved() async throws -> Int {
        for read in heldReads { try await read.cancellationObserved() }
        return heldReads.count
    }

    func releaseHeldRead() {
        for read in heldReads { read.release() }
    }
}
