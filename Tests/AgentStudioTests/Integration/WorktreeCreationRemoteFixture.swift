import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

/// One folder holding a repository with a local bare `origin` and a second bare remote `upstream`,
/// plus a clone of origin that moves origin's branches behind the repository's back. Created
/// worktrees land beside the repository, inside the same folder, so one removal cleans up.
struct WorktreeCreationRemoteFixture {
    let folder: URL
    let repository: URL
    let origin: URL
    let upstream: URL
    let originClone: URL
    let mainCommit: String

    static func create(named name: String) async throws -> Self {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "tmp/filesystem-git-tests/\(name)-\(UUIDv7.generate().uuidString)")
        let repository = folder.appending(path: "repo")
        let origin = folder.appending(path: "origin.git")
        let upstream = folder.appending(path: "upstream.git")
        let originClone = folder.appending(path: "origin-clone")
        do {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try await configureCommitter(repository, initialize: true)
            try "base\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
            try await git(repository, "add", "README.md")
            try await git(repository, "commit", "-m", "base")
            let mainCommit = try await git(repository, "rev-parse", "HEAD")

            for remote in [origin, upstream] {
                try await git(folder, "init", "--bare", remote.path)
                try await git(folder, "--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main")
            }
            try await git(repository, "remote", "add", "origin", origin.path)
            try await git(repository, "remote", "add", "upstream", upstream.path)
            try await git(repository, "push", "origin", "main")
            try await git(repository, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main")
            try await git(folder, "clone", origin.path, originClone.path)
            try await configureCommitter(originClone, initialize: false)
            try await git(originClone, "remote", "add", "upstream", upstream.path)
            return Self(
                folder: folder, repository: repository, origin: origin, upstream: upstream,
                originClone: originClone, mainCommit: mainCommit)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func destroy() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Commits `file` on `branch` in the clone and pushes it to `remote`, starting from the remote's
    /// branch when it exists, else from origin's main. Returns the new tip.
    @discardableResult
    func advance(_ branch: String, on remote: String = "origin", file: String) async throws -> String {
        try await Self.git(originClone, "fetch", "--all")
        let remoteBranches = try await Self.git(originClone, "branch", "-r", "--list", "\(remote)/\(branch)")
        let base = remoteBranches.isEmpty ? "origin/main" : "\(remote)/\(branch)"
        try await Self.git(originClone, "checkout", "-B", branch, base)
        try "\(file)\n".write(to: originClone.appending(path: file), atomically: true, encoding: .utf8)
        try await Self.git(originClone, "add", file)
        try await Self.git(originClone, "commit", "-m", "\(remote) \(branch) \(file)")
        try await Self.git(originClone, "push", remote, "HEAD:refs/heads/\(branch)")
        return try await Self.git(originClone, "rev-parse", "HEAD")
    }

    /// Commits `file` on a local branch without leaving the main worktree on it. Returns the new tip.
    @discardableResult
    func commitLocally(_ branch: String, file: String) async throws -> String {
        let current = try await git("rev-parse", "--abbrev-ref", "HEAD")
        try await git("checkout", branch)
        try "\(file)\n".write(to: repository.appending(path: file), atomically: true, encoding: .utf8)
        try await git("add", file)
        try await git("commit", "-m", "local \(branch) \(file)")
        let tip = try await git("rev-parse", "HEAD")
        try await git("checkout", current)
        return tip
    }

    func destination(for branch: String) throws -> URL {
        try siblingDestination(repository: repository, branch: branch)
    }

    /// Runs `agentstudio worktree new <branch> --repo <repository>` through the real command line. The
    /// remotes are local paths, Git's `file` transport, which the production remote client refuses, so
    /// the runner allows it as the other local-remote tests do.
    func runNew(_ branch: String, _ options: [String] = [], json: Bool) async -> WorktreeCreationRun {
        let probe = WorktreeCreationCommandLineProbe()
        let exit = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--repo", repository.path] + options + (json ? ["--json"] : []),
            currentDirectory: repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) },
            runner: WorktreeOperationRunner(
                remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file])))
        )
        return WorktreeCreationRun(exit: exit, output: probe.outputSnapshot(), errors: probe.errorSnapshot())
    }

    /// A client stub over the real SDK client for the repository, replacing only what a test passes: a
    /// branch-use read error, the error every fork throws, or the fork itself.
    func stubClient(
        branchUseFailure: GitDataPlaneError? = nil,
        forkFailure: GitWorktreeForkError = .rejected(reason: .clientCapabilityUnavailable),
        forkHandler: (
            @Sendable (GitForkWorktreeRequest) async -> Result<GitForkWorktreeResult, GitWorktreeForkError>
        )? = nil
    ) async throws -> WorktreeOperationClientStub {
        let realClient = LibGit2AgentStudioGitLocalClient()
        let snapshot = try #require(await realClient.worktrees(for: repository).first)
        let identity = try await realClient.repositoryIdentity(for: repository)
        let mainWorktree = try #require(identity.mainWorktreePath).standardizedFileURL
        return WorktreeOperationClientStub(
            startPath: mainWorktree, snapshot: snapshot, identity: identity, baseClient: realClient,
            forkFailure: forkFailure, branchUseFailure: branchUseFailure, forkHandler: forkHandler)
    }

    /// `new <branch>` (opening an existing branch) from the main worktree through the runner instead of the
    /// command line, so the client can be a stub. The fetch runs, over the `file` transport as in `runNew`.
    func runCreate(_ branch: String, client: WorktreeOperationClientStub) async -> WorktreeOperationOutcome {
        let runner = WorktreeOperationRunner(
            client: client, remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file])))
        return await runner.run(
            .create(
                WorktreeCreateRequest(
                    start: client.startPath, branch: branch, create: false, source: .mainWorktree,
                    startBranch: nil, materialization: .copyOnWrite, fetchPolicy: .fetch)))
    }

    /// Every ref with its target, and the folder's entries, where any created destination would appear.
    func observedState() async throws -> WorktreeCreationFixtureState {
        WorktreeCreationFixtureState(
            references: try await git("for-each-ref", "--format=%(refname) %(objectname)"),
            folderEntries: try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted())
    }

    @discardableResult
    func git(_ arguments: String...) async throws -> String {
        try await worktreeCreationGit(at: repository, arguments: arguments)
    }

    @discardableResult
    static func git(_ directory: URL, _ arguments: String...) async throws -> String {
        try await worktreeCreationGit(at: directory, arguments: arguments)
    }

    private static func configureCommitter(_ directory: URL, initialize: Bool) async throws {
        if initialize {
            try await git(directory, "init")
            try await git(directory, "symbolic-ref", "HEAD", "refs/heads/main")
        }
        try await git(directory, "config", "user.email", "worktree-creation-tests@example.com")
        try await git(directory, "config", "user.name", "Worktree Creation Tests")
        try await git(directory, "config", "commit.gpgsign", "false")
        try await git(directory, "config", "tag.gpgsign", "false")
    }
}

/// What a refused or failed `new` must leave exactly as it found it.
struct WorktreeCreationFixtureState: Equatable {
    let references: String
    let folderEntries: [String]
}

/// One `new` run through the real command line.
struct WorktreeCreationRun {
    let exit: Int32
    let output: [String]
    let errors: [String]

    var line: String? { output.count == 1 ? output[0] : nil }

    func created() throws -> WorktreeCreationCommandLineDocuments.CreatedDocument {
        try JSONDecoder().decode(
            WorktreeCreationCommandLineDocuments.CreatedDocument.self, from: Data(try #require(line).utf8))
    }

    func refused() throws -> WorktreeCreationCommandLineDocuments.RefusedDocument {
        try JSONDecoder().decode(
            WorktreeCreationCommandLineDocuments.RefusedDocument.self, from: Data(try #require(line).utf8))
    }
}

/// One `new` run and what LR31's line and the worktree's HEAD must be afterwards.
struct WorktreeCreationLineCase {
    let branch: String
    let options: [String]
    let commit: String
    /// What follows the path in parentheses: the materialization word and its notes.
    let details: String

    init(_ branch: String, _ options: [String], _ commit: String, _ details: String) {
        self.branch = branch
        self.options = options
        self.commit = commit
        self.details = details
    }
}
