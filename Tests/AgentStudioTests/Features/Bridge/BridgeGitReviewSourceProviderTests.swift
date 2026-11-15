import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

struct BridgeGitReviewSourceProviderTests {
    @Test("AgentStudioGit adapter maps diff metadata and lazily loads Bridge content handles")
    func agentStudioGitAdapterMapsDiffMetadataAndLazilyLoadsBridgeContentHandles() async throws {
        let fixture = try await makeLazyContentFixture()

        #expect(fixture.comparison.changedFiles.first?.path == fixture.filePath)
        #expect(
            fixture.comparison.changedFiles.first?.oldContentHash
                == gitBlobSHA1ContentHash(fixture.baseContent)
        )
        #expect(
            fixture.comparison.changedFiles.first?.newContentHash
                == gitBlobSHA1ContentHash(fixture.headContent)
        )
        #expect(fixture.comparison.changedFiles.first?.contentHashAlgorithm == "git-blob-sha1")
        #expect(!fixture.headHandle.handleId.contains("/"))
        #expect(
            fixture.headHandle.handleId
                == BridgeProductContentHandleIdentity.handleId(
                    endpointId: fixture.headHandle.endpointId,
                    itemId: fixture.headHandle.itemId,
                    role: fixture.headHandle.role,
                    contentHash: fixture.headHandle.contentHash
                )
        )
        #expect(fixture.loadedBaseContent.data == Data(fixture.baseContent.utf8))
        #expect(fixture.loadedBaseContent.contentHash == gitBlobSHA1ContentHash(fixture.baseContent))
        #expect(fixture.loadedBaseContent.contentHashAlgorithm == "git-blob-sha1")
        #expect(fixture.loadedContent.data == Data(fixture.headContent.utf8))
        #expect(fixture.loadedContent.contentHash == gitBlobSHA1ContentHash(fixture.headContent))
        #expect(fixture.loadedContent.contentHashAlgorithm == "git-blob-sha1")
        #expect(
            await fixture.gitClient.recordedDiffRequests() == [
                GitDiffRequest(repositoryPath: fixture.repositoryPath, base: .commit("abc123"), compare: .workingTree)
            ]
        )
        #expect(
            await fixture.gitClient.recordedContentRequests() == [
                GitContentRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .commit("abc123"),
                    path: fixture.filePath,
                    maxSizeBytes: Int64(AppPolicies.Bridge.contentMaxBytesPerItem)
                ),
                GitContentRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .workingTree,
                    path: fixture.filePath,
                    maxSizeBytes: Int64(AppPolicies.Bridge.contentMaxBytesPerItem)
                ),
            ]
        )
    }

    @Test("AgentStudioGit adapter reads every git-ref tree path scope")
    func agentStudioGitAdapterReadsEveryGitRefTreePathScope() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-tree-test")
        let endpoint = makeBridgeEndpoint(endpointId: "abc123", kind: .gitRef)
        let sourcesRequest = GitTreeReadRequest(
            repositoryPath: repositoryPath,
            revision: .named("abc123"),
            path: "Sources"
        )
        let testsRequest = GitTreeReadRequest(
            repositoryPath: repositoryPath,
            revision: .named("abc123"),
            path: "Tests"
        )
        let gitClient = AgentStudioGitLocalClientFake(
            treeSnapshotByRequest: [
                sourcesRequest: gitTreeSnapshot(path: "Sources/App/View.swift", oid: "source-oid"),
                testsRequest: gitTreeSnapshot(path: "Tests/App/ViewTests.swift", oid: "test-oid"),
            ]
        )
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)

        let result = try await provider.readTree(
            BridgeTreeReadRequest(
                endpoint: endpoint,
                pathScope: ["Sources", "Tests"],
                reviewGeneration: 3
            )
        )

        #expect(result.descriptors.map(\.headPath) == ["Sources/App/View.swift", "Tests/App/ViewTests.swift"])
        #expect(await gitClient.recordedTreeRequests() == [sourcesRequest, testsRequest])
    }

    @Test("AgentStudioGit adapter rejects tree reads for non-revision endpoint kinds")
    func agentStudioGitAdapterRejectsTreeReadsForNonRevisionEndpointKinds() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-tree-test")
        let endpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let gitClient = AgentStudioGitLocalClientFake()
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)

        await #expect(throws: BridgeProviderFailure.self) {
            try await provider.readTree(
                BridgeTreeReadRequest(
                    endpoint: endpoint,
                    pathScope: [],
                    reviewGeneration: 3
                )
            )
        }
        #expect(await gitClient.recordedTreeRequests().isEmpty)
    }

    @Test("AgentStudioGit adapter classifies libgit2 file read failures without raw paths")
    func agentStudioGitAdapterClassifiesLibGit2FileReadFailuresWithoutRawPaths() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-file-read-failure-test")
        let rawPath = "/Users/shravansunder/Documents/dev/project-dev/secret/.gitignore"
        let gitClient = AgentStudioGitLocalClientFake(
            diffFailure: .libgit2Failure(
                code: -1,
                klass: 2,
                message: "could not open '\(rawPath)': Operation not permitted"
            )
        )
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)

        do {
            _ = try await provider.compareEndpoints(
                BridgeEndpointComparisonRequest(
                    query: makeBridgeReviewQuery(baseEndpointId: "base", headEndpointId: "head"),
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    reviewGeneration: 1
                )
            )
            Issue.record("Expected git data-plane failure")
        } catch BridgeProviderFailure.providerFailed(let message) {
            #expect(
                message
                    == "gitDataPlane:libgit2Failure:code=-1:klass=2:reason=operationNotPermitted"
            )
            #expect(!message.contains(rawPath))
        }
    }

    @Test("AgentStudioGit tree filesystem fallback preserves sanitized git failure details")
    func agentStudioGitTreeFilesystemFallbackPreservesSanitizedGitFailureDetails() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-tree-fallback-failure-test")
        let rawPath = "/Users/shravansunder/Documents/dev/project-dev/secret/.gitignore"
        let fullStatusOptions = GitStatusOptions(includeIgnored: false, includeUntracked: true)
        let trackedStatusOptions = GitStatusOptions(includeIgnored: false, includeUntracked: false)
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: AgentStudioGitLocalClientFake(
                diffFailure: .libgit2Failure(
                    code: -1,
                    klass: 2,
                    message: "file changed before we could read it"
                ),
                treeFailure: .libgit2Failure(
                    code: -3,
                    klass: 4,
                    message: "too many open files while reading '\(rawPath)'"
                ),
                statusFailureByOptions: [
                    fullStatusOptions: .libgit2Failure(
                        code: -1,
                        klass: 2,
                        message: "file changed before we could read it"
                    ),
                    trackedStatusOptions: .libgit2Failure(
                        code: -1,
                        klass: 2,
                        message: "file changed before we could read it"
                    ),
                ]
            ),
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)

        do {
            _ = try await provider.compareEndpoints(
                BridgeEndpointComparisonRequest(
                    query: makeBridgeReviewQuery(baseEndpointId: "HEAD", headEndpointId: "working"),
                    baseEndpoint: makeBridgeEndpoint(endpointId: "HEAD", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working", kind: .workingTree),
                    reviewGeneration: 17
                )
            )
            Issue.record("Expected tree filesystem fallback failure")
        } catch BridgeProviderFailure.providerFailed(let message) {
            #expect(
                message
                    == "gitDataPlane:treeFilesystemFallback:failed:status=git.libgit2Failure:code=-1:klass=2:reason=fileReadFailed:tree=git.libgit2Failure:code=-3:klass=4:reason=tooManyOpenFiles"
            )
            #expect(!message.contains(rawPath))
        }
    }

    @Test("AgentStudioGit adapter falls back to status when working-tree diff hits a volatile file")
    func agentStudioGitAdapterFallsBackToStatusWhenWorkingTreeDiffHitsVolatileFile() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-status-fallback-test")
        let stablePath = "Sources/App/View.swift"
        let volatilePath = "tmp/reloading.log"
        let baseContent = "old source"
        let headContent = "new source"
        let baseEndpoint = makeBridgeEndpoint(endpointId: "HEAD", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let gitClient = AgentStudioGitLocalClientFake(
            diffFailure: .libgit2Failure(
                code: -1,
                klass: 2,
                message: "file changed before we could read it"
            ),
            contentByLocator: [
                GitContentLocator(target: .commit("HEAD"), path: stablePath): gitContentPayload(baseContent),
                GitContentLocator(target: .workingTree, path: stablePath): gitContentPayload(headContent),
            ],
            statusSnapshot: gitStatusSnapshot(
                repositoryPath: repositoryPath,
                entries: [
                    gitStatusEntry(path: stablePath, worktreeState: .modified),
                    gitStatusEntry(path: volatilePath, worktreeState: .modified),
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
                reviewGeneration: 12
            )
        )
        let package = try BridgeReviewPackageBuilder.build(
            request: BridgeReviewPackageBuildRequest(
                packageId: "package",
                query: query,
                comparison: comparison,
                checkpointIds: [],
                reviewGeneration: 12,
                generatedAtUnixMilliseconds: 10
            )
        )
        let stableItem = try #require(package.itemsById.values.first { $0.headPath == stablePath })
        let headHandle = try #require(stableItem.contentRoles.head)
        let loadedContent = try await provider.loadContent(
            BridgeContentLoadRequest(handle: headHandle, requestedGeneration: 12)
        )

        #expect(comparison.changedFiles.map(\.path) == [stablePath, volatilePath])
        #expect(comparison.changedFiles.first?.oldContentHash == bridgeSHA256ContentHash(baseContent))
        #expect(comparison.changedFiles.first?.newContentHash == bridgeSHA256ContentHash(headContent))
        #expect(comparison.changedFiles.first?.contentHashAlgorithm == "sha256")
        #expect(package.itemsById.values.contains { $0.headPath == volatilePath })
        #expect(await gitClient.recordedDiffRequests().count == 1)
        #expect(await gitClient.recordedStatusRequestsCount() == 1)
        #expect(loadedContent.data == Data(headContent.utf8))
    }

    @Test(
        "AgentStudioGit adapter preserves status fallback entries when content metadata cannot load",
        arguments: [false, true], [BridgeSourceEndpoint.Kind.workingTree, .index]
    )
    func agentStudioGitAdapterPreservesStatusFallbackEntriesWhenContentMetadataCannotLoad(
        contentQueueIsFull: Bool, headKind: BridgeSourceEndpoint.Kind
    ) async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-status-fallback-metadata-loss-test")
        let volatilePath = "tmp/reloading.log"
        let baseEndpoint = makeBridgeEndpoint(endpointId: "HEAD", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "fallback-head", kind: headKind)
        let gitClient = AgentStudioGitLocalClientFake(
            diffFailure: .libgit2Failure(
                code: -1,
                klass: 2,
                message: "file changed before we could read it"
            ),
            statusSnapshot: gitStatusSnapshot(
                repositoryPath: repositoryPath,
                entries: [
                    gitStatusEntry(
                        path: volatilePath,
                        indexState: headKind == .index ? .modified : nil,
                        worktreeState: headKind == .workingTree ? .modified : nil
                    )
                ]
            )
        )
        try await withBridgeGitContentQueuePressure(
            enabled: contentQueueIsFull, rootURL: repositoryPath
        ) { context in
            let adapter = AgentStudioGitBridgeReviewDataClient(
                repositoryPath: repositoryPath,
                client: gitClient,
                gitReadContext: context,
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
                    reviewGeneration: 14
                )
            )
            let package = try BridgeReviewPackageBuilder.build(
                request: BridgeReviewPackageBuildRequest(
                    packageId: "package",
                    query: query,
                    comparison: comparison,
                    checkpointIds: [],
                    reviewGeneration: 14,
                    generatedAtUnixMilliseconds: 10
                )
            )
            let item = try #require(package.itemsById.values.first)

            #expect(comparison.changedFiles.map(\.path) == [volatilePath])
            #expect(comparison.changedFiles.first?.oldContentHash?.hasPrefix("status-fallback:") == true)
            #expect(comparison.changedFiles.first?.newContentHash?.hasPrefix("status-fallback:") == true)
            #expect(comparison.changedFiles.first?.contentHashAlgorithm == "status-fallback-sha256")
            #expect(item.headPath == volatilePath)
            #expect(item.contentRoles.base != nil)
            #expect(item.contentRoles.head != nil)
            #expect(await gitClient.recordedDiffRequests().count == 1)
            #expect(await gitClient.recordedStatusRequestsCount() == 1)
            #expect(await gitClient.recordedContentRequests().count == (contentQueueIsFull ? 0 : 2))
        }
    }

    @Test("AgentStudioGit adapter retries status fallback without untracked files")
    func agentStudioGitAdapterRetriesStatusFallbackWithoutUntrackedFiles() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-status-fallback-tracked-only-test")
        let stablePath = "Sources/App/View.swift"
        let baseContent = "old source"
        let headContent = "new source"
        let fullStatusOptions = GitStatusOptions(includeIgnored: false, includeUntracked: true)
        let trackedStatusOptions = GitStatusOptions(includeIgnored: false, includeUntracked: false)
        let baseEndpoint = makeBridgeEndpoint(endpointId: "HEAD", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let gitClient = AgentStudioGitLocalClientFake(
            diffFailure: .libgit2Failure(
                code: -1,
                klass: 2,
                message: "file changed before we could read it"
            ),
            contentByLocator: [
                GitContentLocator(target: .commit("HEAD"), path: stablePath): gitContentPayload(baseContent),
                GitContentLocator(target: .workingTree, path: stablePath): gitContentPayload(headContent),
            ],
            statusSnapshotByOptions: [
                trackedStatusOptions: gitStatusSnapshot(
                    repositoryPath: repositoryPath,
                    entries: [
                        gitStatusEntry(path: stablePath, worktreeState: .modified)
                    ]
                )
            ],
            statusFailureByOptions: [
                fullStatusOptions: .libgit2Failure(
                    code: -1,
                    klass: 2,
                    message: "file changed before we could read it"
                )
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
                reviewGeneration: 13
            )
        )
        let package = try BridgeReviewPackageBuilder.build(
            request: BridgeReviewPackageBuildRequest(
                packageId: "package",
                query: query,
                comparison: comparison,
                checkpointIds: [],
                reviewGeneration: 13,
                generatedAtUnixMilliseconds: 10
            )
        )

        #expect(comparison.changedFiles.map(\.path) == [stablePath])
        #expect(package.orderedItemIds.count == 1)
        #expect(package.orderedItemIds.first?.hasPrefix("item-status-") == true)
        #expect(
            await gitClient.recordedStatusOptions() == [
                fullStatusOptions,
                trackedStatusOptions,
            ]
        )
    }

    @Test("AgentStudioGit adapter falls back to tree and filesystem when status also hits a volatile file")
    func agentStudioGitAdapterFallsBackToTreeAndFilesystemWhenStatusAlsoHitsVolatileFile() async throws {
        let repositoryPath = try await FilesystemTestGitRepo.create(named: "bridge-review-tree-filesystem-fallback")
        defer { FilesystemTestGitRepo.destroy(repositoryPath) }
        let filePath = "Sources/App/View.swift"
        let baseContent = "old source"
        let headContent = "new source"
        let fullStatusOptions = GitStatusOptions(includeIgnored: false, includeUntracked: true)
        let trackedStatusOptions = GitStatusOptions(includeIgnored: false, includeUntracked: false)
        let rootTreeRequest = GitTreeReadRequest(repositoryPath: repositoryPath, revision: .named("HEAD"), path: nil)
        let baseEndpoint = makeBridgeEndpoint(endpointId: "HEAD", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let fileURL = repositoryPath.appending(path: filePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try headContent.write(to: fileURL, atomically: true, encoding: .utf8)
        let gitClient = AgentStudioGitLocalClientFake(
            diffFailure: .libgit2Failure(
                code: -1,
                klass: 2,
                message: "file changed before we could read it"
            ),
            treeSnapshotByRequest: [
                rootTreeRequest: gitTreeSnapshot(path: filePath, oid: gitBlobSHA1ContentHash(baseContent))
            ],
            statusFailureByOptions: [
                fullStatusOptions: .libgit2Failure(
                    code: -1,
                    klass: 2,
                    message: "file changed before we could read it"
                ),
                trackedStatusOptions: .libgit2Failure(
                    code: -1,
                    klass: 2,
                    message: "file changed before we could read it"
                ),
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
                reviewGeneration: 15
            )
        )
        let package = try BridgeReviewPackageBuilder.build(
            request: BridgeReviewPackageBuildRequest(
                packageId: "package",
                query: query,
                comparison: comparison,
                checkpointIds: [],
                reviewGeneration: 15,
                generatedAtUnixMilliseconds: 10
            )
        )

        #expect(comparison.changedFiles.map(\.path) == [filePath])
        #expect(comparison.changedFiles.first?.oldContentHash == gitBlobSHA1ContentHash(baseContent))
        #expect(comparison.changedFiles.first?.newContentHash == gitBlobSHA1ContentHash(headContent))
        #expect(comparison.changedFiles.first?.contentHashAlgorithm == "git-blob-sha1")
        #expect(package.itemsById.values.first?.headPath == filePath)
        #expect(await gitClient.recordedStatusOptions() == [fullStatusOptions, trackedStatusOptions])
        #expect(await gitClient.recordedTreeRequests() == [rootTreeRequest])
    }

    @Test("AgentStudioGit adapter returns hidden large descriptor when open file content exceeds the cap")
    func agentStudioGitAdapterReturnsLargeDescriptorWhenOpenFileContentExceedsCap() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-large-file-test")
        let endpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let filePath = "Sources/App/LargeView.swift"
        let locator = GitContentLocator(target: .workingTree, path: filePath)
        let gitClient = AgentStudioGitLocalClientFake(
            contentFailureByLocator: [
                locator: .contentTooLarge(
                    path: filePath,
                    sizeBytes: Int64(AppPolicies.Bridge.contentMaxBytesPerItem + 1),
                    maxSizeBytes: Int64(AppPolicies.Bridge.contentMaxBytesPerItem)
                )
            ]
        )
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)

        let descriptor = try await provider.readReviewItemDescriptor(
            BridgeReviewItemDescriptorRequest(
                endpoint: endpoint,
                path: filePath,
                reviewGeneration: 4
            )
        )

        #expect(descriptor.fileClass == .large)
        #expect(descriptor.isHiddenByDefault)
        #expect(descriptor.contentRoles.allHandles.isEmpty)
        #expect(descriptor.sizeBytes == AppPolicies.Bridge.contentMaxBytesPerItem + 1)
        #expect(
            await gitClient.recordedContentRequests() == [
                GitContentRequest(
                    repositoryPath: repositoryPath,
                    target: .workingTree,
                    path: filePath,
                    maxSizeBytes: Int64(AppPolicies.Bridge.contentMaxBytesPerItem)
                )
            ]
        )
    }

    @Test("AgentStudioGit adapter retains generation-scoped content locators")
    func agentStudioGitAdapterRetainsGenerationScopedContentLocators() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-adapter-prune-test")
        let filePath = "Sources/App/View.swift"
        let headContent = "new source"
        let baseEndpoint = makeBridgeEndpoint(endpointId: "abc123", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let changedFile = GitDiffFile(
            fileId: "source",
            path: filePath,
            previousPath: nil,
            changeKind: .modified,
            oldContentHash: gitBlobSHA1ContentHash("old source"),
            newContentHash: gitBlobSHA1ContentHash(headContent),
            contentHashAlgorithm: "git-blob-sha1",
            oldMode: nil,
            newMode: nil,
            additions: 1,
            deletions: 1,
            isBinary: false,
            sizeBytes: Int64(headContent.utf8.count)
        )
        let gitClient = AgentStudioGitLocalClientFake(
            diffSnapshot: GitDiffSnapshot(files: [changedFile]),
            contentByLocator: [
                GitContentLocator(target: .workingTree, path: filePath): gitContentPayload(headContent)
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

        let generationOnePackage = try await buildPackage(
            provider: provider,
            query: query,
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            reviewGeneration: 1
        )
        let staleHandle = try #require(generationOnePackage.itemsById["item-source"]?.contentRoles.head)
        let generationTwoPackage = try await buildPackage(
            provider: provider,
            query: query,
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            reviewGeneration: 2
        )
        let currentHandle = try #require(generationTwoPackage.itemsById["item-source"]?.contentRoles.head)

        let retainedContent = try await provider.loadContent(
            BridgeContentLoadRequest(handle: staleHandle, requestedGeneration: 1)
        )
        await #expect(throws: BridgeProviderFailure.self) {
            try await provider.loadContent(
                BridgeContentLoadRequest(handle: staleHandle, requestedGeneration: 2)
            )
        }
        let currentContent = try await provider.loadContent(
            BridgeContentLoadRequest(handle: currentHandle, requestedGeneration: 2)
        )

        #expect(retainedContent.data == Data(headContent.utf8))
        #expect(currentContent.data == Data(headContent.utf8))
    }

    @Test("AgentStudioGit adapter builds a review package for HEAD against a dirty working tree")
    func agentStudioGitAdapterBuildsReviewPackageForHeadAgainstDirtyWorkingTree() async throws {
        let repositoryPath = try await FilesystemTestGitRepo.create(named: "bridge-review-head-working-tree")
        defer { FilesystemTestGitRepo.destroy(repositoryPath) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryPath)
        let baseEndpoint = BridgeSourceEndpoint(
            endpointId: "baseline-head",
            kind: .gitRef,
            repoId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            worktreeId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            label: "HEAD",
            createdAtUnixMilliseconds: 1,
            contentSetHash: "sha256:HEAD",
            providerIdentity: "HEAD"
        )
        let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: LibGit2AgentStudioGitLocalClient(),
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)
        let query = makeBridgeReviewQuery(
            baseEndpointId: baseEndpoint.endpointId,
            headEndpointId: headEndpoint.endpointId
        )

        let package = try await buildPackage(
            provider: provider,
            query: query,
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            reviewGeneration: 7
        )

        let itemPaths = package.itemsById.values.compactMap(\.headPath).sorted()
        #expect(itemPaths == ["tracked.txt", "untracked.txt"])
    }

    @Test("git review source provider forwards through backend-neutral client")
    func gitReviewSourceProviderForwardsThroughBackendNeutralClient() async throws {
        let baseEndpoint = makeBridgeEndpoint(endpointId: "base", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "head", kind: .workingTree)
        let changedFile = makeBridgeEndpointChangedFile(
            fileId: "source",
            path: "Sources/App/View.swift",
            sizeBytes: 100
        )
        let comparison = BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: [changedFile]
        )
        let client = BridgeGitReviewDataClientFake(comparison: comparison)
        let provider = BridgeGitReviewSourceProvider(client: client)
        let query = makeBridgeReviewQuery()

        let result = try await provider.compareEndpoints(
            BridgeEndpointComparisonRequest(
                query: query,
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                reviewGeneration: 1
            )
        )

        #expect(result == comparison)
        #expect(await client.recordedComparisonRequestsCount() == 1)
    }

    @Test("git review source provider preserves content handle identity")
    func gitReviewSourceProviderPreservesContentHandleIdentity() async throws {
        let handle = makeBridgeContentHandle(itemId: "item-source", role: .head, reviewGeneration: 2)
        let expectedResult = makeContentResult(handle: handle, data: "content")
        let client = BridgeGitReviewDataClientFake(contentResult: expectedResult)
        let provider = BridgeGitReviewSourceProvider(client: client)

        let result = try await provider.loadContent(
            BridgeContentLoadRequest(handle: handle, requestedGeneration: 2)
        )

        #expect(result == expectedResult)
        #expect(await client.recordedContentRequestsCount() == 1)
    }
}

private struct GitAdapterLazyContentFixture {
    let repositoryPath: URL
    let filePath: String
    let baseContent: String
    let headContent: String
    let gitClient: AgentStudioGitLocalClientFake
    let comparison: BridgeEndpointComparison
    let headHandle: BridgeContentHandle
    let loadedBaseContent: BridgeContentLoadResult
    let loadedContent: BridgeContentLoadResult
}

private func makeLazyContentFixture() async throws -> GitAdapterLazyContentFixture {
    let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-adapter-test")
    let filePath = "Sources/App/View.swift"
    let baseContent = "old source with extra bytes"
    let headContent = "new source"
    let baseEndpoint = makeBridgeEndpoint(endpointId: "abc123", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
    let gitClient = AgentStudioGitLocalClientFake(
        diffSnapshot: GitDiffSnapshot(
            files: [
                GitDiffFile(
                    fileId: "source",
                    path: filePath,
                    previousPath: nil,
                    changeKind: .modified,
                    oldContentHash: gitBlobSHA1ContentHash(baseContent),
                    newContentHash: gitBlobSHA1ContentHash(headContent),
                    contentHashAlgorithm: "git-blob-sha1",
                    oldMode: nil,
                    newMode: nil,
                    additions: 1,
                    deletions: 1,
                    isBinary: false,
                    sizeBytes: Int64(headContent.utf8.count)
                )
            ]
        ),
        contentByLocator: [
            GitContentLocator(target: .commit("abc123"), path: filePath): gitContentPayload(baseContent),
            GitContentLocator(target: .workingTree, path: filePath): gitContentPayload(headContent),
        ]
    )
    let provider = BridgeGitReviewSourceProvider(
        client: AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: makeBridgeGitReadContext(rootURL: repositoryPath),
            statusPhysicalGate: makeBridgeStatusPhysicalGate()
        )
    )
    let query = makeBridgeReviewQuery(
        baseEndpointId: baseEndpoint.endpointId,
        headEndpointId: headEndpoint.endpointId
    )
    let comparison = try await provider.compareEndpoints(
        BridgeEndpointComparisonRequest(
            query: query,
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            reviewGeneration: 9
        )
    )
    let package = try BridgeReviewPackageBuilder.build(
        request: BridgeReviewPackageBuildRequest(
            packageId: "package",
            query: query,
            comparison: comparison,
            checkpointIds: [],
            reviewGeneration: 9,
            generatedAtUnixMilliseconds: 10
        )
    )
    let item = try #require(package.itemsById["item-source"])
    let baseHandle = try #require(item.contentRoles.base)
    let headHandle = try #require(item.contentRoles.head)
    let contentLoaderCache = BridgeReviewContentLoaderCache(provider: provider)
    let productAdmission = try BridgeProductAdmissionTestContext.make()
    let loadedBaseContent = try await contentLoaderCache.load(
        handle: baseHandle,
        productAdmission: productAdmission.context
    )
    let loadedContent = try await contentLoaderCache.load(
        handle: headHandle,
        productAdmission: productAdmission.context
    )
    return GitAdapterLazyContentFixture(
        repositoryPath: repositoryPath,
        filePath: filePath,
        baseContent: baseContent,
        headContent: headContent,
        gitClient: gitClient,
        comparison: comparison,
        headHandle: headHandle,
        loadedBaseContent: loadedBaseContent,
        loadedContent: loadedContent
    )
}

private func buildPackage(
    provider: BridgeGitReviewSourceProvider,
    query: BridgeReviewQuery,
    baseEndpoint: BridgeSourceEndpoint,
    headEndpoint: BridgeSourceEndpoint,
    reviewGeneration: BridgeReviewGeneration
) async throws -> BridgeReviewPackage {
    let comparison = try await provider.compareEndpoints(
        BridgeEndpointComparisonRequest(
            query: query,
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            reviewGeneration: reviewGeneration
        )
    )
    return try BridgeReviewPackageBuilder.build(
        request: BridgeReviewPackageBuildRequest(
            packageId: "package-\(reviewGeneration)",
            query: query,
            comparison: comparison,
            checkpointIds: [],
            reviewGeneration: reviewGeneration,
            generatedAtUnixMilliseconds: 10
        )
    )
}

private func gitTreeSnapshot(path: String, oid: String) -> GitTreeSnapshot {
    GitTreeSnapshot(
        revision: GitResolvedRevision(oid: "abc123", shortName: nil),
        entries: [
            GitTreeEntry(
                path: path,
                oid: oid,
                mode: 0o100644,
                isTree: false,
                sizeBytes: 100
            )
        ]
    )
}

private func gitStatusEntry(
    path: String,
    previousPath: String? = nil,
    indexState: GitStatusState? = nil,
    worktreeState: GitStatusState? = nil,
    ignored: Bool = false,
    untracked: Bool = false
) -> GitStatusEntry {
    GitStatusEntry(
        path: path,
        previousPath: previousPath,
        indexState: indexState,
        worktreeState: worktreeState,
        ignored: ignored,
        untracked: untracked
    )
}

private func gitStatusSnapshot(
    repositoryPath: URL,
    entries: [GitStatusEntry]
) -> GitStatusFactsSnapshot {
    GitStatusFactsSnapshot(
        repositoryRoot: repositoryPath,
        worktreePath: repositoryPath,
        generatedAtUnixMilliseconds: 10,
        head: GitHeadSnapshot(kind: .branch, oid: "abc123", shortName: "main"),
        originResolution: .confirmedAbsent,
        summary: GitStatusFactSummary(
            changedFileCount: entries.count,
            stagedFileCount: entries.filter { $0.indexState != nil }.count,
            unstagedFileCount: entries.filter { $0.worktreeState != nil }.count,
            untrackedFileCount: entries.filter(\.untracked).count,
            ignoredFileCount: entries.filter(\.ignored).count,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: false
        ),
        entries: entries
    )
}
