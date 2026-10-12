import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer

struct BridgeDevelopmentObservationFixture {
    let bus: EventBus<RuntimeEnvelope>
    let fseventClient: ControllableFSEventStreamClient
    let gitProvider: BridgeDevelopmentObservationGitProvider
    let probe: BridgeDevelopmentObservationProbe
    let source: BridgeDevelopmentProductSource

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "bridge-development-seeded-observation-tests")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        try Data("let observationProof = true\n".utf8).write(to: root.appending(path: "Sources/App.swift"))
        return Self(
            bus: EventBus(name: "BridgeDevelopmentObservationTests"),
            fseventClient: ControllableFSEventStreamClient(),
            gitProvider: BridgeDevelopmentObservationGitProvider(),
            probe: BridgeDevelopmentObservationProbe(),
            source: makeSource(root: root)
        )
    }

    static func makeSource(root: URL) -> BridgeDevelopmentProductSource {
        BridgeDevelopmentProductSource(
            paneID: UUID(uuidString: "00000000-0000-7000-8000-000000000063")!,
            paneState: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: root.path,
                    baseline: WorkspaceBaseline(contributionTarget: .ref(name: "HEAD"))
                )
            ),
            repoID: UUID(uuidString: "00000000-0000-7000-8000-000000000061")!,
            reviewedSubjectLabel: "observation-tests",
            worktreeID: UUID(uuidString: "00000000-0000-7000-8000-000000000062")!,
            worktreeRoot: root
        )
    }

    func makeObservation(routingStep: HeldStep<Void>? = nil) -> BridgeDevelopmentSeededWorktreeObservation {
        BridgeDevelopmentSeededWorktreeObservation(
            source: source,
            dependencies: .init(
                bus: bus, fseventStreamClient: fseventClient, gitWorkingTreeProvider: gitProvider,
                filesystemDebounceWindow: .zero, filesystemMaximumFlushLatency: .zero, gitCoalescingWindow: .zero
            ),
            invalidationSink: { invalidation in
                await probe.record(invalidation)
                if case .filesChanged(let changeset) = invalidation,
                    changeset.paths == ["Sources/Held.swift"], let routingStep
                {
                    try? await routingStep.arrive(())
                }
            }
        )
    }

    func fileEnvelope(path: String, root: URL? = nil, sequence: UInt64) -> RuntimeEnvelope {
        .worktree(
            WorktreeEnvelope(
                source: .system(.builtin(.filesystemWatcher)), seq: sequence, timestamp: .now,
                repoId: source.repoID, worktreeId: source.worktreeID,
                event: .filesystem(
                    .filesChanged(
                        changeset: FileChangeset(
                            worktreeId: source.worktreeID, repoId: source.repoID, rootPath: root ?? source.worktreeRoot,
                            paths: [path], timestamp: .now, batchSeq: sequence
                        )))
            ))
    }

    func statusEnvelope(branch: String, root: URL? = nil, sequence: UInt64) -> RuntimeEnvelope {
        .worktree(
            WorktreeEnvelope(
                source: .system(.builtin(.gitWorkingDirectoryProjector)), seq: sequence, timestamp: .now,
                repoId: source.repoID, worktreeId: source.worktreeID,
                event: .gitWorkingDirectory(
                    .snapshotChanged(
                        snapshot: GitWorkingTreeSnapshot(
                            worktreeId: source.worktreeID, repoId: source.repoID, rootPath: root ?? source.worktreeRoot,
                            summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0), branch: branch
                        )))
            ))
    }

    func removeRoot() { try? FileManager.default.removeItem(at: source.worktreeRoot) }
}

actor BridgeDevelopmentObservationGitProvider: GitWorkingTreeStatusProvider {
    private var branch = "feature/observation-proof"
    func setBranch(_ branch: String) { self.branch = branch }
    func statusResult(for _: URL, pathspecs: [String]?) -> GitWorkingTreeStatusResult {
        .available(
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: pathspecs?.contains("Sources/App.swift") == true ? branch : "feature/observation-proof",
                origin: nil
            ))
    }
}

enum SeededObservationScope: String, Hashable, Sendable {
    case files, status, terminalOrder, admission, routingRejection
}

enum SeededObservationFact: Sendable {
    case filesChanged(FileChangeset)
    case statusChanged(GitWorkingTreeStatus)
    case routingCancelled
    case terminal(FSEventStreamRuntimeTerminal)
    case routingFence

    var description: String {
        switch self {
        case .filesChanged(let changeset): "filesChanged \(changeset.paths)"
        case .statusChanged(let status): "statusChanged \(status.branch ?? "nil")"
        case .routingCancelled: "in-flight routing cancellation observed"
        case .terminal(let terminal): "fact admission closed: \(terminal)"
        case .routingFence: "ordered routing fence"
        }
    }
}

actor BridgeDevelopmentObservationProbe {
    nonisolated let facts = FactRecorder<SeededObservationScope, SeededObservationFact>(
        vocabulary: .init(
            describeScope: { $0.rawValue }, describeFact: { $0.description },
            isClosing: { scope, fact in
                switch (scope, fact) {
                case (.admission, .terminal), (.terminalOrder, .terminal), (.routingRejection, .routingFence): true
                default: false
                }
            }
        ))
    private(set) var fileChangesets: [FileChangeset] = []
    private(set) var statuses: [GitWorkingTreeStatus] = []
    private(set) var terminals: [FSEventStreamRuntimeTerminal] = []
    private var admissionWindow = false
    private var rejectionWindow = false

    func beginAdmissionWindow() { admissionWindow = true }
    func beginRejectionWindow() { rejectionWindow = true }

    func record(_ invalidation: BridgePaneWorktreeProductInvalidation) {
        let fact: SeededObservationFact
        switch invalidation {
        case .filesChanged(let changeset):
            fileChangesets.append(changeset)
            fact = .filesChanged(changeset)
            facts.append(scope: .files, fact: fact)
        case .statusChanged(let status):
            if status.branch == "observation-routing-fence" {
                facts.append(scope: .routingRejection, fact: .routingFence)
                return
            }
            statuses.append(status)
            fact = .statusChanged(status)
            facts.append(scope: .status, fact: fact)
        }
        if admissionWindow { facts.append(scope: .admission, fact: fact) }
        if rejectionWindow { facts.append(scope: .routingRejection, fact: fact) }
    }

    func recordTerminal(_ terminal: FSEventStreamRuntimeTerminal) {
        terminals.append(terminal)
        facts.append(scope: .terminalOrder, fact: .terminal(terminal))
        facts.append(scope: .admission, fact: .terminal(terminal))
    }

    nonisolated func nextFiles(paths: [String]) async throws -> FileChangeset {
        while true {
            let fact = try await facts.expectNext(
                in: .files, where: { _ in true }, "filesystem invalidation for \(paths)")
            if case .filesChanged(let changeset) = fact, changeset.paths == paths { return changeset }
        }
    }

    nonisolated func nextStatus(branch: String? = nil) async throws -> GitWorkingTreeStatus {
        let fact = try await facts.expectNext(
            in: .status,
            where: { fact in
                guard case .statusChanged(let status) = fact else { return false }
                return branch == nil || status.branch == branch
            }, "new accepted Git status \(branch ?? "snapshot")")
        guard case .statusChanged(let status) = fact else { preconditionFailure("status vocabulary") }
        return status
    }

    nonisolated func finish() async throws {
        facts.receive(.ended)
        try await facts.finish()
    }
}

func withSeededObservationCleanup(
    observation: BridgeDevelopmentSeededWorktreeObservation,
    probe: BridgeDevelopmentObservationProbe,
    operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        await observation.shutdown()
        try await probe.finish()
    } catch {
        await observation.shutdown()
        try? await probe.finish()
        throw error
    }
}
