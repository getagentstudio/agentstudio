import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("FilesystemPathFilter")
struct FilesystemPathFilterTests {
    @Test("batch ancestor cache distinguishes composed and decomposed prefixes")
    func batchAncestorCacheDistinguishesUnicodeSpellings() throws {
        // Arrange: the existing regex wildcard consumes one scalar after caf,
        // so it matches NFC é but not the two-scalar NFD e + combining acute.
        let rootPath = try makeRootWithGitIgnore(lines: ["caf?"])
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)
        let expectations: [(path: String, ignored: Bool, disposition: FilesystemPathDisposition)] = [
            ("caf\u{00E9}/first.swift", true, .ignoredByPolicy),
            ("cafe\u{0301}/second.swift", false, .projected),
        ]

        for orderedExpectations in [expectations, Array(expectations.reversed())] {
            var ancestorCache = FilesystemPathFilter.DirectoryIgnoreCache()
            for expectation in orderedExpectations {
                // Act
                let disposition = filter.classify(relativePath: expectation.path, ancestorCache: &ancestorCache)
                let ignored = filter.isIgnored(relativePath: expectation.path, ancestorCache: &ancestorCache)

                // Assert: either batch order must preserve the literal rule outcomes.
                #expect(disposition == expectation.disposition)
                #expect(ignored == expectation.ignored)
            }
        }
    }

    @Test("batch ancestor cache preserves the path-only ignore rule table")
    func batchAncestorCachePreservesPathOnlyRuleTable() throws {
        // Arrange
        let rootPath = try makeRootWithGitIgnore(
            lines: [
                ".build-*/", "!.build-agent-1/keep.log", "*.log", "!keep.log",
                "/root-only.txt", "unanchored/", "cache/", ".git/",
            ]
        )
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try "regular file".write(to: rootPath.appending(path: "cache"), atomically: true, encoding: .utf8)
        let filter = FilesystemPathFilter.load(forRootPath: rootPath)
        let expectations: [(path: String, ignored: Bool, disposition: FilesystemPathDisposition)] = [
            (".build-agent-1/checkouts/dep/Sources/file.swift", true, .ignoredByPolicy),
            (".build-agent-1/checkouts/dep/.git/index", true, .ignoredByPolicy),
            // A negated descendant cannot reopen an ignored directory.
            (".build-agent-1/keep.log", true, .ignoredByPolicy),
            ("logs/app.log", true, .ignoredByPolicy),
            ("logs/keep.log", false, .projected),
            ("beside/keep.log", false, .projected),
            ("root-only.txt", true, .ignoredByPolicy),
            ("nested/root-only.txt", false, .projected),
            ("unanchored/child.txt", true, .ignoredByPolicy),
            ("nested/unanchored/deep/child.txt", true, .ignoredByPolicy),
            // Known v2 limitation: directory-only rules also match a same-named
            // leaf file because this path-only policy has no file-kind input.
            ("cache", true, .ignoredByPolicy),
            ("cache/deep/child.txt", true, .ignoredByPolicy),
            // Raw ignore matching sees .git/, but classification always bypasses
            // that policy for the owning repository's status-relevant Git state.
            (".git/index", true, .gitInternal),
            (".git/config", true, .projected),
            (".git/objects/aa/bb", true, .gitObjectDatabase),
        ]

        for orderedExpectations in [expectations, Array(expectations.reversed())] {
            var ancestorCache = FilesystemPathFilter.DirectoryIgnoreCache()
            for expectation in orderedExpectations {
                // Act
                let disposition = filter.classify(relativePath: expectation.path, ancestorCache: &ancestorCache)
                let ignored = filter.isIgnored(relativePath: expectation.path, ancestorCache: &ancestorCache)

                // Assert: literal outcomes come from rule ordering and terminal
                // excluded ancestors, including the admitted path-only limitation.
                #expect(disposition == expectation.disposition)
                #expect(ignored == expectation.ignored)
            }
        }
    }

    @Test("batch ancestor decisions reset when the filter generation changes")
    func batchAncestorDecisionsResetWithFilterGeneration() throws {
        // Arrange
        let rootPath = try makeRootWithGitIgnore(lines: ["blocked/"])
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let originalFilter = FilesystemPathFilter.load(forRootPath: rootPath)
        let copiedFilter = originalFilter
        try "other/\n".write(to: rootPath.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        let reloadedFilter = FilesystemPathFilter.load(forRootPath: rootPath)
        let expectations: [(filter: FilesystemPathFilter, path: String, ignored: Bool)] = [
            (originalFilter, "blocked/deep/first", true),
            (copiedFilter, "blocked/deep/second", true),
            (reloadedFilter, "blocked/deep/third", false),
            (reloadedFilter, "other/deep/first", true),
            (originalFilter, "other/deep/second", false),
            (originalFilter, "blocked/deep/fourth", true),
        ]
        var ancestorCache = FilesystemPathFilter.DirectoryIgnoreCache()

        for expectation in expectations {
            // Act
            let ignored = expectation.filter.isIgnored(relativePath: expectation.path, ancestorCache: &ancestorCache)

            // Assert: switching generations resets both true and false decisions.
            #expect(ignored == expectation.ignored)
        }
    }

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
