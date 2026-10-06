import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioBridge

struct BridgeGitReviewBoundaryTests {
    @Test("revision not-found becomes an unavailable endpoint")
    func revisionNotFoundBecomesUnavailableEndpoint() async {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-revision-not-found-test")
        let endpoint = makeBridgeEndpoint(endpointId: "baseline-head", kind: .gitRef)
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: AgentStudioGitLocalClientFake(
                revisionResolutionFailure: .libgit2Failure(
                    code: -3,
                    klass: 4,
                    message: "revspec 'HEAD' not found"
                )
            ),
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )

        do {
            _ = try await adapter.resolveEndpoint(BridgeEndpointResolutionRequest(endpoint: endpoint))
            Issue.record("Expected unavailable endpoint")
        } catch BridgeProviderFailure.unavailableEndpoint(let endpointId) {
            #expect(endpointId == endpoint.endpointId)
        } catch {
            Issue.record("Expected unavailable endpoint, got \(error)")
        }
    }

    @Test("AgentStudioGit adapter preserves gitlink modes and omits gitlink locators")
    func agentStudioGitAdapterPreservesGitlinkModesAndOmitsGitlinkLocators() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-gitlink-adapter-test")
        let baseEndpoint = makeBridgeEndpoint(endpointId: "base", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "head", kind: .workingTree)
        let gitClient = AgentStudioGitLocalClientFake(
            diffSnapshot: GitDiffSnapshot(
                files: [
                    GitDiffFile(
                        fileId: "submodule",
                        path: "Dependencies/Package",
                        previousPath: nil,
                        changeKind: .modified,
                        oldContentHash: "old-commit",
                        newContentHash: "new-file",
                        contentHashAlgorithm: "git-oid",
                        oldMode: 0o160000,
                        newMode: 0o100644,
                        additions: 1,
                        deletions: 1,
                        isBinary: false,
                        sizeBytes: 8
                    )
                ]
            )
        )
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)
        let query = makeBridgeReviewQuery(
            baseEndpointId: baseEndpoint.endpointId,
            headEndpointId: headEndpoint.endpointId
        )

        let comparison = try await provider.compareEndpoints(
            BridgeEndpointComparisonRequest(
                query: query,
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                reviewGeneration: 3
            )
        )
        let package = try BridgeReviewPackageBuilder.build(
            request: BridgeReviewPackageBuildRequest(
                packageId: "package",
                query: query,
                comparison: comparison,
                checkpointIds: [],
                reviewGeneration: 3,
                generatedAtUnixMilliseconds: 4
            )
        )

        #expect(comparison.changedFiles.first?.oldMode == 0o160000)
        #expect(comparison.changedFiles.first?.newMode == 0o100644)
        #expect(package.itemsById["item-submodule"]?.contentRoles.base == nil)
        #expect(package.itemsById["item-submodule"]?.contentRoles.head != nil)
        #expect(await adapter.registeredContentLocatorCount() == 1)
    }

    @Test("AgentStudioGit shared capture maps locked failures without exposing raw prose")
    func agentStudioGitSharedCaptureMapsLockedFailuresWithoutExposingRawProse() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-shared-capture-failure-test")
        let filePath = "Sources/App/View.swift"
        let rawMessage = "locked while reading /Users/example/private/repository"
        let baseEndpoint = makeBridgeEndpoint(endpointId: "base", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "head", kind: .workingTree)
        let changedFile = GitDiffFile(
            fileId: "source",
            path: filePath,
            previousPath: nil,
            changeKind: .modified,
            oldContentHash: "old-content",
            newContentHash: "new-content",
            contentHashAlgorithm: "git-oid",
            oldMode: 0o100644,
            newMode: 0o100644,
            additions: 1,
            deletions: 1,
            isBinary: false,
            sizeBytes: 8
        )
        let gitClient = AgentStudioGitLocalClientFake(
            diffSnapshot: GitDiffSnapshot(files: [changedFile]),
            contentFailureByLocator: [
                GitContentLocator(target: .workingTree, path: filePath): .locked(message: rawMessage)
            ]
        )
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)
        let query = makeBridgeReviewQuery(
            baseEndpointId: baseEndpoint.endpointId,
            headEndpointId: headEndpoint.endpointId
        )
        let comparison = try await provider.compareEndpoints(
            BridgeEndpointComparisonRequest(
                query: query,
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                reviewGeneration: 3
            )
        )
        let package = try BridgeReviewPackageBuilder.build(
            request: BridgeReviewPackageBuildRequest(
                packageId: "package",
                query: query,
                comparison: comparison,
                checkpointIds: [],
                reviewGeneration: 3,
                generatedAtUnixMilliseconds: 4
            )
        )

        let handles = package.itemsById.values.flatMap(\.contentRoles.allHandles)
        let headHandle = try #require(handles.first { $0.role == .head })
        let backing = try await adapter.captureSharedContent(
            handles: handles,
            freshnessKey: await adapter.gitReadFreshnessKey(for: 3)
        )
        try await adapter.installSharedContent(backing: backing, handles: handles)

        do {
            _ = try await adapter.loadContent(
                BridgeContentLoadRequest(handle: headHandle, requestedGeneration: 3)
            )
            Issue.record("Expected locked Git data-plane failure")
        } catch BridgeProviderFailure.providerFailed(let message) {
            #expect(message == "gitDataPlane:locked")
            #expect(!message.contains(rawMessage))
        } catch {
            Issue.record("Expected BridgeProviderFailure, got \(type(of: error))")
        }
        backing.invalidate()
        await backing.waitUntilInvalidationCleanupCompletes()
    }

    @Test("AgentStudioGit maps unsupported failures without exposing raw prose")
    func agentStudioGitMapsUnsupportedFailuresWithoutExposingRawProse() async {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-unsupported-failure-test")
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: AgentStudioGitLocalClientFake(),
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )

        let failure = await adapter.bridgeFailure(
            for: .unsupported(message: "unsupported at /Users/example/private/repository")
        )

        guard case .providerFailed(let message) = failure else {
            Issue.record("Expected providerFailed")
            return
        }
        #expect(message == "gitDataPlane:unsupported")
    }

    @Test("AgentStudioGit maps new lock and permission failures without exposing paths")
    func agentStudioGitMapsLockAndPermissionFailuresWithoutExposingPaths() async {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-lock-failure-test")
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: AgentStudioGitLocalClientFake(),
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let lockPath = URL(fileURLWithPath: "/Users/example/private/repository/.git/index.lock")
        let failures: [(GitDataPlaneError, String)] = [
            (
                .lockHeld(GitLockFact(path: lockPath, resource: .index(worktreePath: repositoryPath))),
                "gitDataPlane:locked"
            ),
            (.lockUnidentified(.packedRefs), "gitDataPlane:locked"),
            (.permissionDenied(path: lockPath), "gitDataPlane:permissionDenied"),
        ]

        for (error, expectedMessage) in failures {
            let failure = await adapter.bridgeFailure(for: error)
            guard case .providerFailed(let message) = failure else {
                Issue.record("Expected providerFailed for \(error)")
                continue
            }
            #expect(message == expectedMessage)
            #expect(!message.contains(lockPath.path))
        }
    }
}
