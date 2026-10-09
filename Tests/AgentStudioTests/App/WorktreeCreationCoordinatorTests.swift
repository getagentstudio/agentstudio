import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// Order ledger for the creation sequence. Real publication and real Git are proven by
/// `WatchedFolderPublicationHoldIntegrationTests` and `WorktreeCreationEndToEndTests`.
@MainActor
@Suite("Worktree creation coordinator", .serialized)
struct WorktreeCreationCoordinatorTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("From Default holds, creates from the resolved reference, releases, then rescans")
    func successOrdersHoldCreateReleaseRefresh() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let presented = PresentedFailures()
        let coordinator = Self.makeCoordinator(fixture: fixture, ledger: ledger, presented: presented)

        let outcome = await coordinator.startCreation(try fixture.request(branch: "feat/ledger")).value

        let destination = fixture.watchedRoot.appending(path: "repo.feat-ledger", directoryHint: .isDirectory)
            .standardizedFileURL
        #expect(outcome == .created(destination: destination))
        #expect(
            await ledger.events == [
                .hold(destination),
                .create(
                    GitCreateWorktreeRequest(
                        repositoryPath: fixture.repository.repoPath,
                        destinationPath: destination,
                        mode: .newBranch(
                            name: "feat/ledger", startPoint: .named("refs/remotes/origin/main"), upstream: nil)
                    )),
                .release,
                .refresh(fixture.watchedPath.id),
            ])
        #expect(presented.failures.isEmpty)
    }

    @Test("a local main reference is passed to the SDK when there is no origin default")
    func localMainStartPoint() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let coordinator = Self.makeCoordinator(
            fixture: fixture,
            ledger: ledger,
            presented: PresentedFailures(),
            defaultStartPoint: .resolved(displayRef: "main", startPoint: "refs/heads/main")
        )
        let outcome = await coordinator.startCreation(try fixture.request(branch: "feat/local-main")).value
        #expect(
            outcome
                == .created(
                    destination: fixture.watchedRoot.appending(
                        path: "repo.feat-local-main", directoryHint: .isDirectory
                    ).standardizedFileURL))
        #expect(
            await ledger.events.contains { event in
                if case .create(let request) = event,
                    case .newBranch(_, let startPoint, _) = request.mode
                {
                    return startPoint == .named("refs/heads/main")
                }
                return false
            })
    }

    @Test("From Branch creates at the selected local branch reference")
    func selectedBranchStartPoint() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let coordinator = Self.makeCoordinator(fixture: fixture, ledger: ledger, presented: PresentedFailures())

        let outcome = await coordinator.startCreation(
            try fixture.request(branch: "feat/new", kind: .fromBranch(referenceName: "refs/heads/feature/source"))
        ).value

        let destination = fixture.watchedRoot.appending(path: "repo.feat-new", directoryHint: .isDirectory)
            .standardizedFileURL
        #expect(outcome == .created(destination: destination))
        #expect(
            await ledger.events.contains(
                .create(
                    GitCreateWorktreeRequest(
                        repositoryPath: fixture.repository.repoPath,
                        destinationPath: destination,
                        mode: .newBranch(
                            name: "feat/new", startPoint: .named("refs/heads/feature/source"), upstream: nil)
                    ))))
    }

    @Test("no default branch is a typed failure and still releases publication")
    func noDefaultBranchFails() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let presented = PresentedFailures()
        let coordinator = Self.makeCoordinator(
            fixture: fixture,
            ledger: ledger,
            presented: presented,
            defaultStartPoint: .noDefaultBranch
        )
        let outcome = await coordinator.startCreation(try fixture.request(branch: "feat/no-default")).value
        #expect(outcome == .failed(.noDefaultBranch))
        #expect(presented.failures == [.noDefaultBranch])
        #expect(
            await ledger.events == [
                .hold(
                    fixture.watchedRoot.appending(
                        path: "repo.feat-no-default", directoryHint: .isDirectory
                    ).standardizedFileURL),
                .release,
                .refresh(fixture.watchedPath.id),
            ])
    }

    @Test("an SDK failure releases the hold, still rescans the owning folder, and presents the failure")
    func sdkFailureReleasesHoldAndPresents() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let presented = PresentedFailures()
        let gitError = GitDataPlaneError.libgit2Failure(code: -4, klass: 7, message: "reference already exists")
        let coordinator = Self.makeCoordinator(
            fixture: fixture, ledger: ledger, presented: presented, createError: gitError)

        let outcome = await coordinator.startCreation(try fixture.request(branch: "feat/exists")).value

        #expect(outcome == .failed(.gitFailure(gitError)))
        let events = await ledger.events
        #expect(events.first.map { if case .hold = $0 { true } else { false } } == true)
        #expect(Array(events.suffix(2)) == [.release, .refresh(fixture.watchedPath.id)])
        #expect(presented.failures == [.gitFailure(gitError)])
    }

    @Test("a destination rejection never holds or reaches the SDK")
    func destinationRejectionTouchesNothing() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let presented = PresentedFailures()
        let destination = fixture.watchedRoot.appending(path: "repo.taken", directoryHint: .isDirectory)
            .standardizedFileURL
        let coordinator = Self.makeCoordinator(
            fixture: fixture, ledger: ledger, presented: presented, existingPaths: [destination])

        let outcome = await coordinator.startCreation(try fixture.request(branch: "taken")).value

        #expect(outcome == .failed(.destinationRejected(.destinationExists(destination))))
        #expect(await ledger.events.isEmpty)
        #expect(presented.failures == [.destinationRejected(.destinationExists(destination))])
    }

    @Test("a fork holds, forks the source worktree without a start point, releases, then rescans")
    func forkOrdersHoldForkReleaseRefresh() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let presented = PresentedFailures()
        let coordinator = Self.makeCoordinator(fixture: fixture, ledger: ledger, presented: presented)

        let outcome = await coordinator.startCreation(try fixture.request(branch: "fork/ledger", kind: .fork)).value

        let destination = fixture.watchedRoot.appending(path: "repo.fork-ledger", directoryHint: .isDirectory)
            .standardizedFileURL
        #expect(outcome == .created(destination: destination))
        #expect(
            await ledger.events == [
                .hold(destination),
                .fork(
                    GitForkWorktreeRequest(
                        sourceWorktreePath: fixture.worktree.path,
                        destinationPath: destination,
                        mode: .newBranch(name: "fork/ledger", start: .sourceHead, upstream: nil),
                        materialization: .copyOnWrite,
                        copyRules: GitWorktreeCopyRules(ignoredPaths: .copyAll)
                    )),
                .release,
                .refresh(fixture.watchedPath.id),
            ])
        #expect(presented.failures.isEmpty)
    }

    @Test("a fork preflight rejection releases the hold, still rescans the owning folder, and presents the failure")
    func forkRejectionReleasesHoldAndPresents() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let presented = PresentedFailures()
        let forkError = GitWorktreeForkError.rejected(reason: .crossDevice)
        let coordinator = Self.makeCoordinator(
            fixture: fixture, ledger: ledger, presented: presented, forkError: forkError)

        let outcome = await coordinator.startCreation(try fixture.request(branch: "fork/rejected", kind: .fork)).value

        #expect(outcome == .failed(.forkFailure(forkError)))
        let events = await ledger.events
        #expect(Array(events.suffix(2)) == [.release, .refresh(fixture.watchedPath.id)])
        #expect(presented.failures == [.forkFailure(forkError)])
    }

    @Test("destination probing runs off the main actor; the main actor only sequences")
    func destinationProbingRunsOffMainActor() async throws {
        let fixture = try Self.makeFixture()
        let ledger = CreationLedger()
        let presented = PresentedFailures()
        let probeThreads = ProbeThreadRecorder()
        let coordinator = Self.makeCoordinator(
            fixture: fixture, ledger: ledger, presented: presented, probeThreads: probeThreads)

        _ = await coordinator.startCreation(try fixture.request(branch: "off-main")).value

        let observations = probeThreads.observations
        #expect(!observations.isEmpty)
        #expect(observations.allSatisfy { $0 == .offMainThread })
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: WorkspaceStore
        let watchedRoot: URL
        let watchedPath: WatchedPath
        let repository: Repo
        let worktree: Worktree

        func request(branch: String, kind: WorktreeCreationKind = .fromDefault) throws -> WorktreeCreationRequest {
            WorktreeCreationRequest(
                kind: kind,
                targetId: kind == .fork ? worktree.id : repository.id,
                branchName: try WorktreeBranchName.validated(branch).get()
            )
        }
    }

    private static func makeFixture() throws -> Fixture {
        let store = WorkspaceStore()
        let watchedRoot = URL(
            filePath: "/Users/dev/coordinator-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
        let watchedPath = try #require(store.mutationCoordinator.addWatchedPath(watchedRoot))
        let repositoryPath = watchedRoot.appending(path: "repo", directoryHint: .isDirectory)
        let repository = store.addRepo(at: repositoryPath)
        let mainWorktree = Worktree(repoId: repository.id, name: "repo", path: repositoryPath, isMainWorktree: true)
        store.reconcileDiscoveredWorktrees(repository.id, worktrees: [mainWorktree])
        let resolvedRepository = try #require(store.repositoryTopologyAtom.repo(repository.id))
        let mainWorktreeMatch = resolvedRepository.worktrees.first { $0.isMainWorktree }
        let worktree = try #require(mainWorktreeMatch)
        return Fixture(
            store: store,
            watchedRoot: watchedRoot,
            watchedPath: watchedPath,
            repository: resolvedRepository,
            worktree: worktree
        )
    }

    private static func makeCoordinator(
        fixture: Fixture,
        ledger: CreationLedger,
        presented: PresentedFailures,
        createError: GitDataPlaneError? = nil,
        forkError: GitWorktreeForkError? = nil,
        defaultStartPoint: WorktreeDefaultStartPoint = .resolved(
            displayRef: "origin/main", startPoint: "refs/remotes/origin/main"),
        existingPaths: Set<URL> = [],
        probeThreads: ProbeThreadRecorder = ProbeThreadRecorder()
    ) -> WorktreeCreationCoordinator {
        WorktreeCreationCoordinator(
            topology: fixture.store.repositoryTopologyAtom,
            gitClient: FakeWorktreeCreationGitClient(ledger: ledger, createError: createError, forkError: forkError),
            defaultStartPointResolver: FakeDefaultStartPointResolver(resolution: defaultStartPoint),
            publication: FakeWorktreePublication(ledger: ledger),
            destinationProbe: WorktreeDestinationProbe(
                canonicalWatchedRoot: { root in
                    probeThreads.record()
                    return root
                },
                pathExists: { path in
                    probeThreads.record()
                    return existingPaths.contains(path.standardizedFileURL)
                }
            ),
            presentFailure: { presented.failures.append($0) }
        )
    }
}

private enum CreationEvent: Equatable {
    case hold(URL)
    case create(GitCreateWorktreeRequest)
    case fork(GitForkWorktreeRequest)
    case release
    case refresh(UUID)
}

private actor CreationLedger {
    private(set) var events: [CreationEvent] = []

    func record(_ event: CreationEvent) {
        events.append(event)
    }
}

private struct FakeDefaultStartPointResolver: WorktreeDefaultStartPointResolving {
    let resolution: WorktreeDefaultStartPoint

    func resolveDefaultStartPoint(repositoryPath _: URL) async throws(GitDataPlaneError) -> WorktreeDefaultStartPoint {
        resolution
    }
}

@MainActor
private final class PresentedFailures {
    var failures: [WorktreeCreationFailure] = []
}

private struct FakeWorktreeCreationGitClient: WorktreeCreationGitClient {
    let ledger: CreationLedger
    let createError: GitDataPlaneError?
    let forkError: GitWorktreeForkError?

    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeCreation {
        await ledger.record(.create(request))
        if let createError { throw createError }
        return GitWorktreeCreation(
            worktree: Self.snapshot(destination: request.destinationPath, repositoryPath: request.repositoryPath),
            largeFiles: GitLargeFileFill(materializedCount: 0, missing: [], residuePaths: [], scan: .complete)
        )
    }

    func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError) -> GitForkWorktreeResult {
        await ledger.record(.fork(request))
        if let forkError { throw forkError }
        return GitForkWorktreeResult(
            worktree: Self.snapshot(destination: request.destinationPath, repositoryPath: request.sourceWorktreePath),
            materialization: .copyOnWrite(
                GitWorktreeMaterializationReport(
                    clonedRegularFileCount: 1,
                    createdDirectoryCount: 1,
                    recreatedSymbolicLinkCount: 0,
                    preservedHardLinkCount: 0,
                    preservedGitRepositoryCount: 0,
                    recreatedFIFOCount: 0,
                    logicalRegularFileBytes: 1,
                    skippedEntries: [],
                    normalizedEntries: [],
                    ignoredIncludedPatterns: [], ignoredExcludedCount: 0, nestedWorktreesSkipped: [],
                    sourceState: .asIs, submodulesNotAtStart: [], largeFiles: nil
                ))
        )
    }

    private static func snapshot(destination: URL, repositoryPath: URL) -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: destination.lastPathComponent),
            repositoryID: GitRepositoryID(rawValue: repositoryPath.path),
            displayName: destination.lastPathComponent,
            path: destination,
            canonicalPath: destination,
            gitDirectory: destination.appending(path: ".git"),
            indexPath: destination.appending(path: ".git/index"),
            isMainWorktree: false,
            isLocked: false,
            lockReason: nil,
            head: nil
        )
    }
}

private final class FakeWorktreePublication: WorktreePublicationHolding {
    let ledger: CreationLedger

    init(ledger: CreationLedger) {
        self.ledger = ledger
    }

    func holdPublication(of destination: URL) async -> WatchedFolderPublicationHoldID {
        await ledger.record(.hold(destination))
        return WatchedFolderPublicationHoldID(rawValue: UUIDv7.generate())
    }

    func releasePublicationHold(_: WatchedFolderPublicationHoldID) async {
        await ledger.record(.release)
    }

    func refreshWatchedFolder(_ watchedPathID: UUID, among _: [WatchedPath]) async {
        await ledger.record(.refresh(watchedPathID))
    }
}

/// Records which thread each destination probe ran on. Probes are synchronous, so the
/// main-thread check is exact at the moment of the call.
private final class ProbeThreadRecorder: @unchecked Sendable {
    enum Observation: Equatable { case mainThread, offMainThread }

    private let lock = NSLock()
    private var recorded: [Observation] = []

    var observations: [Observation] { lock.withLock { recorded } }

    func record() {
        let observation: Observation = pthread_main_np() != 0 ? .mainThread : .offMainThread
        lock.withLock { recorded.append(observation) }
    }
}
