import AgentStudioGit
import AgentStudioTestSupport
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Darwin private staged-ref admission")
struct DarwinPrivateStagingRefAdmissionTests {
    @Test(
        "private staging forms preserve the literal path contract",
        arguments: [
            ("refs/agentstudio/staged", true),
            ("refs/agentstudio/staged/attempt", true),
            (".git/refs/agentstudio/staged", true),
            ("repo/.git/refs/agentstudio/staged/attempt/heads/main", true),
            ("./refs/agentstudio/staged", true),
            ("././refs/agentstudio/staged/attempt", true),
            ("/refs/agentstudio/staged", true),
            ("/tmp/repo/.git/refs/agentstudio/staged/attempt", true),
            (" \trefs/agentstudio/staged\n", true),
            ("\n./.git/refs/agentstudio/staged/attempt \t", true),
            ("/工程/仓库/.git/refs/agentstudio/staged/attempt", true),
            ("refs/agentstudio/stage", false),
            ("refs/agentstudio/staged-x", false),
            ("repo/.git/refs/agentstudio/staged-x/attempt", false),
            ("otherrefs/agentstudio/staged/attempt", false),
            (".build-agent-1/checkouts/dep/.git/index", false),
            (".build-agent-1/objects/ab/cd", false),
            ("/工程/仓库/源代码/文件.swift", false),
            ("/tmp/café/refs/agentstudio/stage", false),
            ("", false),
        ])
    func privateStagingFormsMatchLiteralCorpus(path: String, expected: Bool) {
        // Arrange / Act
        let isPrivateStagingPath = FilesystemPathFilter.isAgentStudioPrivateStagingRefPath(path)

        // Assert
        #expect(isPrivateStagingPath == expected)
    }

    @Test(
        "bridged NSString paths preserve staging admission with non-contiguous UTF-8",
        arguments: [
            ("/工程/仓库/.git/refs/agentstudio/staged/attempt", true),
            ("refs/agentstudio/staged/工程/仓库", true),
            ("/工程/仓库/.git/refs/agentstudio/staged", true),
            (" \t/工程/仓库/.git/refs/agentstudio/staged/attempt\n", true),
            ("/工程/仓库/.git/refs/agentstudio/staged-x/attempt", false),
            ("/工程/仓库/otherrefs/agentstudio/staged/attempt", false),
            ("/工程/仓库/.git/refs/agentstudio/stag\u{0}ed/attempt", false),
            ("/工程/仓库/\u{0}/.git/refs/agentstudio/staged/attempt", true),
            ("/工程/仓库/源代码/文件.swift", false),
        ])
    func bridgedPrivateStagingFormsPreserveLiteralContract(path: String, expected: Bool) throws {
        // Arrange: construct Cocoa UTF-16 storage instead of bridging a native Swift string back.
        let codeUnits = Array(path.utf16)
        let bridgedPath = try codeUnits.withUnsafeBufferPointer { buffer in
            let baseAddress = try #require(buffer.baseAddress)
            return NSString(characters: baseAddress, length: buffer.count) as String
        }
        #expect(bridgedPath.utf8.withContiguousStorageIfAvailable { _ in true } == nil)

        // Act
        let isPrivateStagingPath = FilesystemPathFilter.isAgentStudioPrivateStagingRefPath(bridgedPath)

        // Assert
        #expect(isPrivateStagingPath == expected)
        #expect(FilesystemPathFilter.isAgentStudioPrivateStagingRefPath(path) == expected)
    }

    @Test("raw events and ordinary paths share one private-staging classification site")
    func privateStagingAdmissionHasOneClassificationSite() throws {
        // Arrange: protect the source contraction boundary independently of elapsed time.
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinSharedExactItemObserver.swift"),
            encoding: .utf8)
        let classifierStart = try #require(source.range(of: "package enum DarwinFSEventPathClassifier {"))
        let classifierEnd = try #require(
            source.range(
                of: "package protocol DarwinSharedExactItemStreamLifetime",
                range: classifierStart.upperBound..<source.endIndex))

        // Act
        let classifierSource = String(source[classifierStart.lowerBound..<classifierEnd.lowerBound])
        let stagingClassificationSites =
            classifierSource.components(
                separatedBy: "FilesystemPathFilter.isAgentStudioPrivateStagingRefPath("
            ).count - 1

        // Assert: output semantics alone would pass even while every path is classified twice.
        #expect(stagingClassificationSites == 1)
    }

    @Test("private staged refs are excluded before continuity and ordinary filesystem ingress")
    func privateStagedRefsAreExcludedAtSource() {
        let rootPath = "/tmp/repo"
        let stagedRefPath =
            "/tmp/repo/.git/refs/agentstudio/staged/attempt/refs/heads/main"

        let classification = DarwinFSEventPathClassifier.classify(
            rawEvents: [(path: stagedRefPath, eventId: 41, flags: 0)],
            ordinaryPaths: [stagedRefPath],
            rootPath: rootPath,
            observationScopes: [
                AgentStudioGit.GitStatusObservationScope(
                    kind: .subtree,
                    path: URL(fileURLWithPath: "/tmp/repo/.git/refs")
                )
            ]
        )

        #expect(classification.rawEvents.map(\.hasRelevantMutation) == [false])
        #expect(classification.ordinaryPaths.isEmpty)
    }

    @Test("continuity streams exclude the private staged-ref subtree in the kernel")
    func continuityStreamsExcludePrivateStagedRefSubtree() {
        let refsScope = AgentStudioGit.GitStatusObservationScope(
            kind: .subtree,
            path: URL(fileURLWithPath: "/tmp/repo/.git/refs")
        )

        #expect(
            DarwinFSEventStreamConfiguration.privateStagingExclusionPaths(
                observationScopes: [refsScope]
            ) == ["/tmp/repo/.git/refs/agentstudio/staged"]
        )
        #expect(
            DarwinFSEventStreamConfiguration.privateStagingExclusionPaths(
                sharedParentPath: "/tmp/repo/.git"
            ) == ["/tmp/repo/.git/refs/agentstudio/staged"]
        )
    }
}
