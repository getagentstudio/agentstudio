import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File annotation source witnesses")
struct FileAnnotationSourceWitnessTests {
    @Test(arguments: ["xxxx\nxxxx\n", "The file changed size too.\n"])
    func changedFileRejectsAnnotationWithTypedSourceFailure(replacement: String) async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let snapshot = try fixture.openSnapshot()
        let collector = ProductFileSourceFactCollector()
        try await source.open(subscription: snapshot, productAdmission: fixture.productAdmission.context) { _ in }
        do {
            try await source.applyViewDemand(
                subscriptionId: snapshot.subscriptionId,
                demand: fixture.viewDemand(),
                productAdmission: fixture.productAdmission.context,
                forceRecapture: false
            ) { await collector.append($0, source: source) }
            let payload = try #require(
                (await collector.events).compactMap { event -> BridgeProductFileDescriptorReadyPayload? in
                    guard case .descriptorReady(let ready) = event else { return nil }
                    return ready
                }.first)
            guard case .available(let descriptor) = payload.availability else {
                Issue.record("Expected available file descriptor")
                await source.cancel(subscriptionId: snapshot.subscriptionId)
                return
            }
            try Data(replacement.utf8).write(to: fixture.demandedFileURL)
            var failure: WorktreeAnnotationSourceResolutionError?
            do {
                _ = try await source.captureWorktreeAnnotationSource(
                    origin: .init(
                        path: fixture.demandedPath, startLine: 1, endLine: 1,
                        sourceRole: .file, diffSide: nil, sourceIdentity: descriptor.descriptorId
                    ),
                    productAdmission: fixture.productAdmission.context
                )
            } catch {
                failure = error as? WorktreeAnnotationSourceResolutionError
            }
            #expect(failure == .invalidSource)
        } catch {
            await source.cancel(subscriptionId: snapshot.subscriptionId)
            throw error
        }
        await source.cancel(subscriptionId: snapshot.subscriptionId)
    }

    @Test("annotation source requirements dispatch through the production File source witness")
    func annotationSourceRequirementsUseProductionWitness() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        try await source.open(
            subscription: fixture.openSnapshot(),
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let existentialSource: any BridgePaneProductFileMetadataProducing = source

        // Act
        let generation = try await existentialSource.currentWorktreeAnnotationSourceGeneration(
            productAdmission: fixture.productAdmission.context
        )
        let fingerprint = try await existentialSource.currentWorktreeAnnotationFingerprint(
            productAdmission: fixture.productAdmission.context
        )
        let refresh = try await existentialSource.currentWorktreeAnnotationRefresh(
            requirements: [],
            productAdmission: fixture.productAdmission.context
        )

        // Assert
        #expect(generation == 1)
        #expect(fingerprint == refresh.fingerprint)
        #expect(fingerprint.repositoryID == fixture.repoId.uuidString.lowercased())
        #expect(fingerprint.worktreeID == fixture.worktreeId.uuidString.lowercased())
    }

    @Test(arguments: FileAnnotationRequirementOriginKind.allCases, WorktreeAnnotationSourceRole.allCases)
    func unmaterializedRequirementsCaptureOnlyCompatibleWorkingTreeSource(
        originKind: FileAnnotationRequirementOriginKind,
        originSourceRole: WorktreeAnnotationSourceRole
    ) async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        try await FilesystemTestGitRepo.runGit(at: fixture.rootURL, args: ["init"])
        let source = fixture.makeSource()
        let snapshot = try fixture.openSnapshot()
        let collector = ProductFileSourceFactCollector()

        do {
            try await source.open(
                subscription: snapshot,
                productAdmission: fixture.productAdmission.context
            ) { event in
                await collector.append(event, source: source)
            }
            let existentialSource: any BridgePaneProductFileMetadataProducing = source
            let fingerprint = try await existentialSource.currentWorktreeAnnotationFingerprint(
                productAdmission: fixture.productAdmission.context
            )
            let diffSide: WorktreeAnnotationDiffSide? =
                switch originSourceRole {
                case .file: nil
                case .reviewBase: .deletions
                case .reviewHead: .additions
                }
            let origin: WorktreeAnnotationThreadOrigin =
                switch originKind {
                case .located:
                    .located(
                        .init(
                            repositoryRelativePath: fixture.demandedPath,
                            startLine: 1,
                            endLine: 1,
                            sourceRole: originSourceRole,
                            diffSide: diffSide,
                            sourceIdentity: "origin-source",
                            selectedExcerpt: "line",
                            contextBefore: nil,
                            contextAfter: "line"
                        )
                    )
                case .wholeFile:
                    .wholeFile(
                        repositoryRelativePath: fixture.demandedPath,
                        sourceRole: originSourceRole
                    )
                }
            let requirement = WorktreeAnnotationSourceRefreshRequirement(
                threadID: .generate(),
                origin: origin
            )

            // Act
            let eventsBeforeCapture = await collector.events
            let refresh = try await existentialSource.currentWorktreeAnnotationRefresh(
                requirements: [requirement],
                productAdmission: fixture.productAdmission.context
            )

            // Assert
            #expect(
                !eventsBeforeCapture.contains {
                    if case .descriptorReady = $0 { true } else { false }
                }
            )
            #expect(refresh.fingerprint == fingerprint)
            if originSourceRole == .reviewBase {
                #expect(refresh.material == .unavailable)
                await source.cancel(subscriptionId: snapshot.subscriptionId)
                return
            }
            guard case .available(let files) = refresh.material else {
                Issue.record(
                    "Expected working-tree material for unmaterialized \(originKind) \(originSourceRole.rawValue) origin"
                )
                await source.cancel(subscriptionId: snapshot.subscriptionId)
                return
            }
            let demandedFile = try #require(
                files.first {
                    $0.path == fixture.demandedPath && $0.sourceRole == .file
                }
            )
            #expect(demandedFile.body == "line\nline\n")
            #expect(!demandedFile.sourceIdentity.isEmpty)
            await source.cancel(subscriptionId: snapshot.subscriptionId)
        } catch {
            await source.cancel(subscriptionId: snapshot.subscriptionId)
            throw error
        }
    }
}

enum FileAnnotationRequirementOriginKind: CaseIterable, Sendable {
    case located
    case wholeFile
}
