import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("FilesystemPathFilter")
struct FilesystemPathFilterTests {
    @Test("own Git internals bypass ignore policy while ignored nested Git internals do not")
    func classifiesGitInternalsBeforeIgnorePolicy() throws {
        let rootPath = try makeRootWithGitIgnore(lines: ["*"])
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)

        #expect(filter.classify(relativePath: ".git/index") == .gitInternal)
        #expect(filter.classify(relativePath: "src/.git/config") == .ignoredByPolicy)
        #expect(filter.classify(relativePath: ".git/config") == .projected)
    }

    @Test(
        "ignored build checkouts suppress their nested Git metadata and objects",
        arguments: [
            ".build-agent-1/checkouts/dep/.git/index",
            ".build-agent-1/checkouts/dep/.git/objects/aa/bb",
        ])
    func ignoredBuildCheckoutsSuppressNestedGitPaths(relativePath: String) throws {
        // Arrange
        let rootPath = try makeRootWithGitIgnore(lines: [".build-*"])
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)

        // Act
        let disposition = filter.classify(relativePath: relativePath)

        // Assert
        #expect(disposition == .ignoredByPolicy)
    }

    @Test("non-ignored nested repositories keep their Git dispositions")
    func nonIgnoredNestedRepositoriesKeepGitDispositions() {
        // Arrange
        let filter = FilesystemPathFilter.empty

        // Act / Assert
        #expect(filter.classify(relativePath: "vendor/sub/.git") == .gitInternal)
        #expect(filter.classify(relativePath: "nested/.git/objects/pack/x") == .gitObjectDatabase)
    }

    @Test("classifies git object database writes separately from repository state")
    func classifiesGitObjectDatabaseWritesSeparately() {
        let filter = FilesystemPathFilter.empty

        #expect(filter.classify(relativePath: ".git/objects") == .gitObjectDatabase)
        #expect(filter.classify(relativePath: ".git/objects/aa/bb") == .gitObjectDatabase)
        #expect(filter.classify(relativePath: "nested/.git/objects/pack/data.pack") == .gitObjectDatabase)
        #expect(filter.classify(relativePath: ".git/refs/heads/main") == .gitInternal)
        #expect(filter.classify(relativePath: ".git/index") == .gitInternal)
    }

    @Test("FETCH_HEAD bookkeeping is ignored without suppressing status-relevant Git state")
    func ignoresFetchHeadButPreservesStatusRelevantGitState() {
        let filter = FilesystemPathFilter.empty

        #expect(filter.classify(relativePath: ".git/FETCH_HEAD") == .ignoredByPolicy)
        #expect(filter.classify(relativePath: ".git/FETCH_HEAD.lock") == .ignoredByPolicy)
        #expect(
            filter.classify(relativePath: ".git/refs/agentstudio/staged/attempt/heads/main")
                == .ignoredByPolicy
        )
        #expect(filter.classify(relativePath: ".git/modules/vendor/FETCH_HEAD") == .ignoredByPolicy)
        #expect(filter.classify(relativePath: "nested/.git/FETCH_HEAD") == .ignoredByPolicy)
        #expect(filter.classify(relativePath: ".git/HEAD") == .gitInternal)
        #expect(filter.classify(relativePath: ".git/index") == .gitInternal)
        #expect(filter.classify(relativePath: ".git/packed-refs") == .gitInternal)
        #expect(filter.classify(relativePath: ".git/refs/remotes/origin/main") == .gitInternal)
        #expect(filter.classify(relativePath: ".git/config") == .projected)
    }

    @Test("gitignore supports negation, root anchoring, directory patterns, and single-char wildcard")
    func supportsNegationAnchoringDirectoryAndSingleWildcard() throws {
        let rootPath = try makeRootWithGitIgnore(
            lines: [
                "*.log",
                "!important.log",
                "/root-only.txt",
                "build/",
                "foo?.txt",
            ]
        )
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)

        #expect(filter.isIgnored(relativePath: "debug.log"))
        #expect(!filter.isIgnored(relativePath: "important.log"))
        #expect(filter.isIgnored(relativePath: "root-only.txt"))
        #expect(!filter.isIgnored(relativePath: "src/root-only.txt"))
        #expect(filter.isIgnored(relativePath: "build/output.o"))
        #expect(filter.isIgnored(relativePath: "foo1.txt"))
        #expect(!filter.isIgnored(relativePath: "foo12.txt"))
    }

    @Test("double-star glob and regex metacharacters in file names are handled correctly")
    func supportsDoubleStarAndRegexMetacharacters() throws {
        let rootPath = try makeRootWithGitIgnore(
            lines: [
                "docs/**/*.tmp",
                "file[1].txt",
            ]
        )
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)

        #expect(filter.isIgnored(relativePath: "docs/a/b/c.tmp"))
        #expect(!filter.isIgnored(relativePath: "docs/a/b/c.txt"))
        #expect(filter.isIgnored(relativePath: "file[1].txt"))
        #expect(!filter.isIgnored(relativePath: "filea.txt"))
    }

    @Test("ignored directory patterns suppress descendant filesystem events")
    func ignoredDirectoryPatternSuppressesDescendants() throws {
        let rootPath = try makeRootWithGitIgnore(lines: [".build-*"])
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)

        #expect(filter.classify(relativePath: ".build-agent-1") == .ignoredByPolicy)
        #expect(filter.classify(relativePath: ".build-agent-1/.slot-claim") == .ignoredByPolicy)
    }

    @Test("descendant negation cannot bypass an ignored parent directory")
    func descendantNegationCannotBypassIgnoredParent() throws {
        let rootPath = try makeRootWithGitIgnore(
            lines: [
                ".build-*",
                "!.build-agent-1/.slot-claim",
            ]
        )
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)

        #expect(filter.classify(relativePath: ".build-agent-1/.slot-claim") == .ignoredByPolicy)
    }

    @Test("missing .gitignore falls back to empty ignore policy")
    func missingGitIgnoreFallsBackToEmptyPolicy() throws {
        let rootPath = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: rootPath) }

        let filter = FilesystemPathFilter.load(forRootPath: rootPath)
        #expect(filter.classify(relativePath: "Sources/App.swift") == .projected)
        #expect(!filter.isIgnored(relativePath: "debug.log"))
    }

    @Test("repository activity qualifies projected content and gitignore but not ignored content")
    func repositoryActivityQualifiesWorktreeContent() {
        #expect(
            RepositoryLocalActivityPathClassifier.qualifiesWorktreePath(
                relativePath: "Sources/App.swift",
                disposition: .projected
            )
        )
        #expect(
            RepositoryLocalActivityPathClassifier.qualifiesWorktreePath(
                relativePath: ".gitignore",
                disposition: .ignoredByPolicy
            )
        )
        #expect(
            !RepositoryLocalActivityPathClassifier.qualifiesWorktreePath(
                relativePath: "build/output.o",
                disposition: .ignoredByPolicy
            )
        )
    }

    @Test("repository activity admits exact git state and excludes bookkeeping")
    func repositoryActivityClassifiesGitMetadata() {
        let qualifyingPaths = [
            "/repo/.git/HEAD",
            "/repo/.git/index",
            "/repo/.git/FETCH_HEAD",
            "/repo/.git/packed-refs",
            "/repo/.git/refs/heads/main",
            "/repo/.git/refs/remotes/origin/main",
        ]
        let excludedPaths = [
            "/repo/.git/config",
            "/repo/.git/objects/aa/object",
            "/repo/.git/HEAD.lock",
            "/repo/.git/index.lock",
            "/repo/.git/refs/heads/main.lock",
            "/repo/.git/refs/agentstudio/staged/attempt/heads/main",
            "/Users/example/.gitconfig",
            "/Users/example/.gitignore-global",
        ]

        for path in qualifyingPaths {
            #expect(RepositoryLocalActivityPathClassifier.qualifiesGitMetadataPath(path))
        }
        for path in excludedPaths {
            #expect(!RepositoryLocalActivityPathClassifier.qualifiesGitMetadataPath(path))
        }
    }

    @Test("empty/comment-only .gitignore does not ignore paths")
    func commentOnlyGitIgnoreDoesNotIgnorePaths() throws {
        let rootPath = try makeRootWithGitIgnore(
            lines: [
                "",
                "   ",
                "# generated files",
                " # spaced comment",
            ]
        )
        defer { try? FileManager.default.removeItem(at: rootPath) }

        let filter = FilesystemPathFilter.load(forRootPath: rootPath)
        #expect(filter.classify(relativePath: "build/output.o") == .projected)
        #expect(!filter.isIgnored(relativePath: "Sources/App.swift"))
    }

    private func makeRootWithGitIgnore(lines: [String]) throws -> URL {
        let fileManager = FileManager.default
        let rootPath = fileManager.temporaryDirectory.appending(path: "path-filter-\(UUIDv7.generate().uuidString)")
        try fileManager.createDirectory(at: rootPath, withIntermediateDirectories: true)
        let contents = lines.joined(separator: "\n")
        try contents.write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        return rootPath
    }

    private func makeEmptyRoot() throws -> URL {
        let fileManager = FileManager.default
        let rootPath = fileManager.temporaryDirectory.appending(
            path: "path-filter-empty-\(UUIDv7.generate().uuidString)")
        try fileManager.createDirectory(at: rootPath, withIntermediateDirectories: true)
        return rootPath
    }
}
