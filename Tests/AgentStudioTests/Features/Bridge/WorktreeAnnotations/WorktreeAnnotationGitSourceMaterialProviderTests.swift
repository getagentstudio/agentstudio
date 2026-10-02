import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation agentstudio-git source material", WorktreeAnnotationGitSourceMaterialSeedLifetime())
struct WorktreeAnnotationGitSourceMaterialProviderTests {
    @Test("an unrelated symlink read failure preserves an exact annotation")
    func unrelatedSymlinkReadFailurePreservesExactAnnotation() async throws {
        let repositoryURL = try await makeGitSourceFixture()
        defer { WorktreeAnnotationGitFixture.destroy(repositoryURL) }
        try FileManager.default.createSymbolicLink(
            atPath: repositoryURL.appending(path: "Instructions.md").path,
            withDestinationPath: "Sources/Feature.swift"
        )
        let provider = GitWorktreeAnnotationSourceMaterialProvider(
            client: LibGit2AgentStudioGitLocalClient()
        )
        let session = makeGitSourceSession()
        let thread = makeGitSourceThread(sessionID: session.id)

        let material = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: ["Instructions.md", "Sources/Feature.swift"].map { path in
                    .init(
                        path: path,
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    )
                }
            )
        )
        let result = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: session,
                threads: [thread],
                surface: .file,
                sourceEpoch: "unrelated-symlink",
                currentFingerprint: makeGitSourceFingerprint(),
                material: material
            )
        )

        #expect(result.placements[thread.id]?.placement == .exact)
        #expect(result.placements[thread.id]?.currentPath == "Sources/Feature.swift")
    }

    @Test("working-tree material drives exact relocation and ambiguous placement")
    func workingTreeMaterialDrivesPlacement() async throws {
        let repositoryURL = try await makeGitSourceFixture()
        defer { WorktreeAnnotationGitFixture.destroy(repositoryURL) }
        let provider = GitWorktreeAnnotationSourceMaterialProvider(
            client: LibGit2AgentStudioGitLocalClient()
        )
        let session = makeGitSourceSession()
        let thread = makeGitSourceThread(sessionID: session.id)

        let exactMaterial = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    )
                ]
            )
        )
        let exact = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: session,
                threads: [thread],
                surface: .file,
                sourceEpoch: "working-tree-1",
                currentFingerprint: makeGitSourceFingerprint(),
                material: exactMaterial
            )
        )

        try FileManager.default.moveItem(
            at: repositoryURL.appending(path: "Sources/Feature.swift"),
            to: repositoryURL.appending(path: "Sources/RenamedFeature.swift")
        )
        let relocatedMaterial = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "Sources/RenamedFeature.swift",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    )
                ]
            )
        )
        let relocated = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: session,
                threads: [thread],
                surface: .file,
                sourceEpoch: "working-tree-2",
                currentFingerprint: makeGitSourceFingerprint(),
                material: relocatedMaterial
            )
        )

        let duplicateURL = repositoryURL.appending(path: "Sources/Duplicate.swift")
        try "before\nselected line\nafter\n".write(to: duplicateURL, atomically: true, encoding: .utf8)
        let ambiguousMaterial = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "Sources/RenamedFeature.swift",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    ),
                    .init(
                        path: "Sources/Duplicate.swift",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    ),
                ]
            )
        )
        let ambiguous = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: session,
                threads: [thread],
                surface: .file,
                sourceEpoch: "working-tree-3",
                currentFingerprint: makeGitSourceFingerprint(),
                material: ambiguousMaterial
            )
        )

        #expect(exact.placements[thread.id]?.placement == .exact)
        #expect(relocated.placements[thread.id]?.placement == .relocated)
        #expect(relocated.placements[thread.id]?.currentPath == "Sources/RenamedFeature.swift")
        #expect(ambiguous.placements[thread.id]?.placement == .outdated)
    }

    @Test("working-tree material places a Review head origin on the File surface")
    func workingTreeMaterialPlacesReviewHeadOrigin() async throws {
        let repositoryURL = try await makeGitSourceFixture()
        defer { WorktreeAnnotationGitFixture.destroy(repositoryURL) }
        let provider = GitWorktreeAnnotationSourceMaterialProvider(
            client: LibGit2AgentStudioGitLocalClient()
        )
        let session = makeGitSourceSession()
        let thread = makeGitSourceThread(
            sessionID: session.id,
            sourceRole: .reviewHead,
            diffSide: .additions
        )
        let material = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    )
                ]
            )
        )

        let result = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: session,
                threads: [thread],
                surface: .file,
                sourceEpoch: "working-tree-review-head",
                currentFingerprint: makeGitSourceFingerprint(),
                material: material
            )
        )

        #expect(result.placements[thread.id]?.placement == .exact)
        #expect(result.placements[thread.id]?.currentSourceIdentity != nil)
    }

    @Test("review material reads the exact base and head commits")
    func reviewMaterialReadsBaseAndHeadCommits() async throws {
        let repositoryURL = try await makeGitSourceFixture()
        defer { WorktreeAnnotationGitFixture.destroy(repositoryURL) }
        let baseOID = try await WorktreeAnnotationGitFixture.runGit(
            at: repositoryURL,
            args: ["rev-parse", "HEAD"]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        try "before\nhead line\nafter\n".write(
            to: repositoryURL.appending(path: "Sources/Feature.swift"),
            atomically: true,
            encoding: .utf8
        )
        try await WorktreeAnnotationGitFixture.runGit(at: repositoryURL, args: ["add", "Sources/Feature.swift"])
        try await WorktreeAnnotationGitFixture.runGit(
            at: repositoryURL,
            args: ["commit", "-m", "Head material"]
        )
        let headOID = try await WorktreeAnnotationGitFixture.runGit(
            at: repositoryURL,
            args: ["rev-parse", "HEAD"]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = GitWorktreeAnnotationSourceMaterialProvider(
            client: LibGit2AgentStudioGitLocalClient()
        )

        let material = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .reviewBase,
                        sourceIdentity: .provided("base-handle"),
                        target: .commit(baseOID)
                    ),
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .reviewHead,
                        sourceIdentity: .provided("head-handle"),
                        target: .commit(headOID)
                    ),
                ]
            )
        )

        guard case .available(let files) = material else {
            Issue.record("Expected base and head material")
            return
        }
        #expect(files.map(\.sourceRole) == [.reviewBase, .reviewHead])
        #expect(files.map(\.body) == ["before\nselected line\nafter\n", "before\nhead line\nafter\n"])
    }

    @Test("missing oversized and over-capacity material fail closed")
    func unavailableAndBoundedReadsFailClosed() async throws {
        let repositoryURL = try await makeGitSourceFixture()
        defer { WorktreeAnnotationGitFixture.destroy(repositoryURL) }
        let client = LibGit2AgentStudioGitLocalClient()
        let provider = GitWorktreeAnnotationSourceMaterialProvider(
            client: client,
            maximumCandidateCount: 1,
            maximumFileByteCount: 8
        )
        let missing = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "Sources/Missing.swift",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    )
                ]
            )
        )
        let oversized = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    )
                ]
            )
        )
        let overCapacity = await provider.material(
            .init(
                repositoryPath: repositoryURL,
                candidates: [
                    .init(
                        path: "a",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    ),
                    .init(
                        path: "b",
                        sourceRole: .file,
                        sourceIdentity: .currentFileDescriptor,
                        target: .workingTree
                    ),
                ]
            )
        )

        #expect(missing == .unavailable)
        #expect(oversized == .unavailable)
        #expect(overCapacity == .unavailable)
    }
}

private func makeGitSourceFixture() async throws -> URL {
    try await WorktreeAnnotationGitSourceMaterialSeedCache.shared.makeCopy()
}

private func makeGitSourceSeed() async throws -> URL {
    let repositoryURL = try await WorktreeAnnotationGitFixture.create()
    do {
        let sourcesURL = repositoryURL.appending(path: "Sources")
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try "before\nselected line\nafter\n".write(
            to: sourcesURL.appending(path: "Feature.swift"),
            atomically: true,
            encoding: .utf8
        )
        try await WorktreeAnnotationGitFixture.runGit(at: repositoryURL, args: ["add", "Sources/Feature.swift"])
        try await WorktreeAnnotationGitFixture.runGit(
            at: repositoryURL,
            args: ["commit", "-m", "Source fixture"]
        )
        return repositoryURL
    } catch {
        WorktreeAnnotationGitFixture.destroy(repositoryURL)
        throw error
    }
}

private actor WorktreeAnnotationGitSourceMaterialSeedCache {
    static let shared = WorktreeAnnotationGitSourceMaterialSeedCache()

    private var seedRepositoryURL: URL?

    func prepare() async throws {
        guard seedRepositoryURL == nil else { return }
        seedRepositoryURL = try await makeGitSourceSeed()
    }

    func makeCopy() throws -> URL {
        guard let seedRepositoryURL else {
            throw WorktreeAnnotationSeedCacheError.seedNotPrepared
        }
        let copyURL = FileManager.default.temporaryDirectory.appending(
            path: "annotation-source-material-copy-\(UUIDv7.generate().uuidString)"
        )
        try FileManager.default.copyItem(at: seedRepositoryURL, to: copyURL)
        return copyURL
    }

    func destroySeed() {
        guard let seedRepositoryURL else { return }
        WorktreeAnnotationGitFixture.destroy(seedRepositoryURL)
        self.seedRepositoryURL = nil
    }
}

private enum WorktreeAnnotationSeedCacheError: Error {
    case seedNotPrepared
}

private struct WorktreeAnnotationGitSourceMaterialSeedLifetime: SuiteTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await WorktreeAnnotationGitSourceMaterialSeedCache.shared.prepare()
        do {
            try await function()
        } catch {
            await WorktreeAnnotationGitSourceMaterialSeedCache.shared.destroySeed()
            throw error
        }
        await WorktreeAnnotationGitSourceMaterialSeedCache.shared.destroySeed()
    }
}

private func makeGitSourceFingerprint() -> WorktreeAnnotationSourceFingerprint {
    .init(
        repositoryID: "repo-1",
        worktreeID: "worktree-1",
        fileSourceIdentity: "file-current",
        reviewComparisonOrigin: nil
    )
}

private func makeGitSourceSession() -> WorktreeAnnotationSession {
    .init(
        id: .generate(),
        repositoryID: "repo-1",
        worktreeID: "worktree-1",
        lifecycle: .living,
        sourceRelationship: .applicable,
        acceptedSourceFingerprint: makeGitSourceFingerprint(),
        semanticRevision: 1,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        completedAt: nil
    )
}

private func makeGitSourceThread(
    sessionID: WorktreeAnnotationSessionID,
    sourceRole: WorktreeAnnotationSourceRole = .file,
    diffSide: WorktreeAnnotationDiffSide? = nil
) -> WorktreeAnnotationThread {
    .init(
        id: .generate(),
        sessionID: sessionID,
        origin: .located(
            .init(
                repositoryRelativePath: "Sources/Feature.swift",
                startLine: 2,
                endLine: 2,
                sourceRole: sourceRole,
                diffSide: diffSide,
                sourceIdentity: "file-original",
                selectedExcerpt: "selected line",
                contextBefore: "before",
                contextAfter: "after"
            )
        ),
        resolution: .open,
        createdOrdinal: 0,
        semanticRevision: 0,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        resolvedAt: nil
    )
}

private enum WorktreeAnnotationGitFixture {
    static func create() async throws -> URL {
        let repositoryURL = FileManager.default.temporaryDirectory.appending(
            path: "annotation-source-material-\(UUIDv7.generate().uuidString)"
        )
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try await runGit(at: repositoryURL, args: ["init"])
        try await runGit(at: repositoryURL, args: ["symbolic-ref", "HEAD", "refs/heads/main"])
        try await runGit(at: repositoryURL, args: ["config", "user.email", "annotations@example.invalid"])
        try await runGit(at: repositoryURL, args: ["config", "user.name", "Annotation Tests"])
        try await runGit(at: repositoryURL, args: ["config", "commit.gpgsign", "false"])
        return repositoryURL
    }

    static func destroy(_ repositoryURL: URL) {
        try? FileManager.default.removeItem(at: repositoryURL)
    }

    @discardableResult
    static func runGit(at repositoryURL: URL, args: [String]) async throws -> String {
        let git = try await TestToolResolver.resolved().git
        return try await withoutBlockingCooperativePool {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appending(path: "annotation-git-output-\(UUIDv7.generate().uuidString)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let stdoutURL = outputDirectory.appending(path: "stdout.log")
            let stderrURL = outputDirectory.appending(path: "stderr.log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            process.executableURL = git
            process.arguments = ["-C", repositoryURL.path] + args
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try TestToolResolver.launch(process)
            process.waitUntilExit()
            TestToolResolver.recordFailedExit(process)
            try stdoutHandle.close()
            try stderrHandle.close()
            guard process.terminationStatus == 0 else {
                let errorText = try String(contentsOf: stderrURL, encoding: .utf8)
                throw NSError(
                    domain: "WorktreeAnnotationGitFixture",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errorText]
                )
            }
            return try String(contentsOf: stdoutURL, encoding: .utf8)
        }
    }
}
