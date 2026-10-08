import AgentStudioWorktreeOperations
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Worktree destination policy")
struct WorktreeDestinationPolicyTests {
    private static let watchedRoot = URL(filePath: "/Users/dev/project-dev", directoryHint: .isDirectory)
    private static let repositoryPath = watchedRoot.appending(path: "agent-studio", directoryHint: .isDirectory)

    struct BranchNameCase: Sendable, CustomTestStringConvertible {
        let text: String
        let expected: Result<String, WorktreeBranchNameRejection>
        var testDescription: String { "\"\(text)\"" }
    }

    @Test(
        "branch names follow the typed subset of git check-ref-format",
        arguments: [
            BranchNameCase(text: "feat/worktree-commands", expected: .success("feat/worktree-commands")),
            BranchNameCase(text: "fix-123", expected: .success("fix-123")),
            BranchNameCase(text: "", expected: .failure(.empty)),
            BranchNameCase(text: "has space", expected: .failure(.containsWhitespaceOrControlCharacter)),
            BranchNameCase(text: "a~b", expected: .failure(.containsForbiddenCharacter("~"))),
            BranchNameCase(text: "a:b", expected: .failure(.containsForbiddenCharacter(":"))),
            BranchNameCase(text: "a..b", expected: .failure(.containsForbiddenSequence(".."))),
            BranchNameCase(text: "a@{b", expected: .failure(.containsForbiddenSequence("@{"))),
            BranchNameCase(text: "a//b", expected: .failure(.containsForbiddenSequence("//"))),
            BranchNameCase(text: "-leading", expected: .failure(.invalidComponentBoundary)),
            BranchNameCase(text: "trailing/", expected: .failure(.invalidComponentBoundary)),
            BranchNameCase(text: "feat/.hidden", expected: .failure(.invalidComponentBoundary)),
            BranchNameCase(text: "name.lock", expected: .failure(.invalidComponentBoundary)),
            BranchNameCase(text: "@", expected: .failure(.invalidComponentBoundary)),
            BranchNameCase(text: "HEAD", expected: .failure(.invalidComponentBoundary)),
            // Git accepts these for an existing branch; a branch the app creates may not use them.
            BranchNameCase(text: "release/a\u{00A0}b", expected: .failure(.containsWhitespaceOrControlCharacter)),
            BranchNameCase(
                text: "release/\u{1F469}\u{200D}\u{1F4BB}", expected: .failure(.containsWhitespaceOrControlCharacter)),
        ]
    )
    func branchNameValidation(_ testCase: BranchNameCase) {
        #expect(WorktreeBranchName.validated(testCase.text).map(\.rawValue) == testCase.expected)
    }

    @Test("an overlong branch name is rejected with the policy limit")
    func overlongBranchNameIsRejected() {
        let limit = WorktreeCreationPolicy.maximumBranchNameLength
        let text = String(repeating: "a", count: limit + 1)

        #expect(WorktreeBranchName.validated(text).map(\.rawValue) == .failure(.tooLong(maximumLength: limit)))
    }

    struct SlugCase: Sendable, CustomTestStringConvertible {
        let branch: String
        let slug: String?
        var testDescription: String { "\(branch) -> \(slug ?? "nil")" }
    }

    @Test(
        "branch names map to folder-safe slugs",
        arguments: [
            SlugCase(branch: "feat/worktree-commands", slug: "feat-worktree-commands"),
            SlugCase(branch: "feature/a/b", slug: "feature-a-b"),
            SlugCase(branch: "release_1.2", slug: "release_1.2"),
            SlugCase(branch: "émoji-ünicode", slug: "moji-nicode"),
            SlugCase(branch: "日本", slug: nil),
        ]
    )
    func folderSlugs(_ testCase: SlugCase) throws {
        let branchName = try WorktreeBranchName.validated(testCase.branch).get()

        #expect(WorktreeDestinationNaming.folderSlug(for: branchName) == testCase.slug)
    }

    @Test("the destination is a sibling of the main checkout inside the watched folder that discovers it")
    func destinationIsSiblingInsideWatchedFolder() throws {
        let watchedPath = WatchedPath(path: Self.watchedRoot)
        let branchName = try WorktreeBranchName.validated("feat/worktree-commands").get()

        let destination = try Self.resolve(
            repositoryPath: Self.repositoryPath,
            branchName: branchName,
            watchedPaths: [watchedPath],
            probe: .lexical(pathExists: { _ in false })
        ).get()

        #expect(destination.path.path == "/Users/dev/project-dev/agent-studio.feat-worktree-commands")
        #expect(destination.watchedPath == watchedPath)
    }

    @Test("the deepest containing watched folder owns publication")
    func deepestWatchedFolderWins() throws {
        let outer = WatchedPath(path: URL(filePath: "/Users/dev", directoryHint: .isDirectory))
        let inner = WatchedPath(path: Self.watchedRoot)
        let branchName = try WorktreeBranchName.validated("topic").get()

        let destination = try Self.resolve(
            repositoryPath: Self.repositoryPath,
            branchName: branchName,
            watchedPaths: [outer, inner],
            probe: .lexical(pathExists: { _ in false })
        ).get()

        #expect(destination.watchedPath == inner)
    }

    @Test("private tmp aliases resolve to the same watched folder")
    func privateTmpAliasIsContained() throws {
        let watchedPath = WatchedPath(path: URL(filePath: "/private/tmp/watch", directoryHint: .isDirectory))
        let branchName = try WorktreeBranchName.validated("topic").get()

        let destination = try Self.resolve(
            repositoryPath: URL(filePath: "/tmp/watch/repo", directoryHint: .isDirectory),
            branchName: branchName,
            watchedPaths: [watchedPath],
            probe: .lexical(pathExists: { _ in false })
        ).get()

        #expect(destination.watchedPath == watchedPath)
    }

    @Test("a destination no watched folder discovers is rejected before creation")
    func undiscoverableDestinationIsRejected() throws {
        let branchName = try WorktreeBranchName.validated("topic").get()
        let unrelated = WatchedPath(path: URL(filePath: "/Users/elsewhere", directoryHint: .isDirectory))
        let hiddenParent = WatchedPath(path: URL(filePath: "/Users", directoryHint: .isDirectory))
        let expectedDestination = URL(filePath: "/Users/dev/.hidden/repo.topic", directoryHint: .isDirectory)

        let outside = Self.resolve(
            repositoryPath: Self.repositoryPath,
            branchName: branchName,
            watchedPaths: [unrelated],
            probe: .lexical(pathExists: { _ in false })
        )
        let hidden = Self.resolve(
            repositoryPath: URL(filePath: "/Users/dev/.hidden/repo", directoryHint: .isDirectory),
            branchName: branchName,
            watchedPaths: [hiddenParent],
            probe: .lexical(pathExists: { _ in false })
        )

        guard case .failure(.undiscoverableDestination) = outside else {
            Issue.record("expected an outside destination to be rejected, got \(outside)")
            return
        }
        #expect(hidden == .failure(.undiscoverableDestination(expectedDestination.standardizedFileURL)))
    }

    struct DepthCase: Sendable, CustomTestStringConvertible {
        let label: String
        /// The main checkout the sibling destination is derived from.
        let repositoryPath: String
        let accepted: Bool
        var testDescription: String { label }
    }

    @Test(
        "destinations the watched-folder scanner cannot reach are rejected before creation",
        arguments: [
            DepthCase(label: "sibling at depth 1", repositoryPath: "/Users/dev/watch/repo", accepted: true),
            DepthCase(
                label: "sibling at the scanner's maximum depth",
                repositoryPath: "/Users/dev/watch/a/b/c/repo",
                accepted: true
            ),
            DepthCase(
                label: "sibling one level past the scanner's maximum depth",
                repositoryPath: "/Users/dev/watch/a/b/c/d/repo",
                accepted: false
            ),
            DepthCase(
                label: "shallow linked source whose main repository is deeper",
                repositoryPath: "/Users/dev/watch/deep/er/still/nested/main-repo",
                accepted: false
            ),
        ]
    )
    func scannerDepthLimitsDestinations(_ testCase: DepthCase) throws {
        let branchName = try WorktreeBranchName.validated("topic").get()
        let repositoryPath = URL(filePath: testCase.repositoryPath, directoryHint: .isDirectory)
        let expectedDestination = repositoryPath.deletingLastPathComponent()
            .appending(path: repositoryPath.lastPathComponent + ".topic", directoryHint: .isDirectory)
            .standardizedFileURL

        let result = Self.resolve(
            repositoryPath: repositoryPath,
            branchName: branchName,
            watchedPaths: [WatchedPath(path: URL(filePath: "/Users/dev/watch", directoryHint: .isDirectory))],
            probe: .lexical(pathExists: { _ in false })
        )

        if testCase.accepted {
            #expect((try? result.get())?.path == expectedDestination)
        } else {
            #expect(
                result
                    == .failure(
                        .beyondScannerDepth(expectedDestination, maximumDepth: RepoScanner.defaultMaxDepth)))
        }
    }

    @Test("a symlinked watched folder contains siblings of checkouts discovered through it")
    func symlinkedWatchedRootContainsDiscoveredSibling() throws {
        let branchName = try WorktreeBranchName.validated("topic").get()
        let symlinkRoot = WatchedPath(path: URL(filePath: "/Users/dev/linked-watch", directoryHint: .isDirectory))
        let realRoot = URL(filePath: "/Volumes/work/watch", directoryHint: .isDirectory)
        let probe = WorktreeDestinationProbe(
            canonicalWatchedRoot: {
                $0.standardizedFileURL.path == symlinkRoot.path.standardizedFileURL.path ? realRoot : $0
            },
            pathExists: { _ in false }
        )

        let destination = try Self.resolve(
            repositoryPath: realRoot.appending(path: "repo", directoryHint: .isDirectory),
            branchName: branchName,
            watchedPaths: [symlinkRoot],
            probe: probe
        ).get()

        #expect(destination.path.path == "/Volumes/work/watch/repo.topic")
        #expect(destination.watchedPath == symlinkRoot)
    }

    @Test("an existing destination is rejected as a collision")
    func existingDestinationIsRejected() throws {
        let branchName = try WorktreeBranchName.validated("topic").get()
        let expectedDestination = Self.watchedRoot.appending(path: "agent-studio.topic", directoryHint: .isDirectory)

        let result = Self.resolve(
            repositoryPath: Self.repositoryPath,
            branchName: branchName,
            watchedPaths: [WatchedPath(path: Self.watchedRoot)],
            probe: .lexical(pathExists: { $0 == expectedDestination.standardizedFileURL })
        )

        #expect(result == .failure(.destinationExists(expectedDestination.standardizedFileURL)))
    }

    @Test("a branch with no folder-safe characters is rejected")
    func emptySlugIsRejected() throws {
        let branchName = try WorktreeBranchName.validated("日本").get()

        let result = Self.resolve(
            repositoryPath: Self.repositoryPath,
            branchName: branchName,
            watchedPaths: [WatchedPath(path: Self.watchedRoot)],
            probe: .lexical(pathExists: { _ in false })
        )

        #expect(result == .failure(.emptyFolderSlug))
    }

    private static func resolve(
        repositoryPath: URL,
        branchName: WorktreeBranchName,
        watchedPaths: [WatchedPath],
        probe: WorktreeDestinationProbe
    ) -> Result<WorktreeCreationDestination, WorktreeDestinationRejection> {
        WorktreeDestinationPolicy.resolve(
            repositoryPath: repositoryPath,
            branchName: branchName,
            watchedPaths: watchedPaths,
            probe: probe
        )
    }
}

extension WorktreeDestinationProbe {
    /// Watched roots taken as written: the pure placement cases do not involve symlinks.
    fileprivate static func lexical(pathExists: @escaping @Sendable (URL) -> Bool) -> Self {
        Self(canonicalWatchedRoot: { $0 }, pathExists: pathExists)
    }
}
