import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
struct RefreshRevisionFixture {
    let baseEndpoint: BridgeSourceEndpoint
    let headEndpoint: BridgeSourceEndpoint
    let refreshedFile: BridgeEndpointChangedFile
    let secondRefreshedFile: BridgeEndpointChangedFile
    let provider: BridgeReviewSourceProviderFake
    let controller: BridgePaneController
    let commandId: UUID
}

@MainActor
func makeRefreshRevisionFixture() async throws -> RefreshRevisionFixture {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
    let initialFile = makeBridgeEndpointChangedFile(
        fileId: "old",
        path: "Sources/App/Old.swift",
        sizeBytes: 100
    )
    let refreshedFile = makeBridgeEndpointChangedFile(
        fileId: "new",
        path: "Sources/App/New.swift",
        sizeBytes: 100
    )
    let secondRefreshedFile = makeBridgeEndpointChangedFile(
        fileId: "newer",
        path: "Sources/App/Newer.swift",
        sizeBytes: 100
    )
    let provider = BridgeReviewSourceProviderFake(
        comparison: BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: [initialFile]
        ),
        contentByHandleId: [:]
    )
    let paneId = UUIDv7.generate()
    let controller = BridgePaneController(
        paneId: paneId,
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(
                rootPath: "/tmp/worktree",
                baseline: .unstaged)
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Refresh revision",
            facets: PaneContextFacets(
                repoId: headEndpoint.repoId,
                worktreeId: headEndpoint.worktreeId,
                cwd: URL(fileURLWithPath: "/tmp/worktree")
            )
        ),
        reviewSourceProvider: provider,
        initialPaneActivity: .foreground
    )
    try await showReviewInNativeFixture(controller)
    return RefreshRevisionFixture(
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        refreshedFile: refreshedFile,
        secondRefreshedFile: secondRefreshedFile,
        provider: provider,
        controller: controller,
        commandId: UUID()
    )
}

@MainActor
func setRefreshComparison(
    _ fixture: RefreshRevisionFixture,
    changedFile: BridgeEndpointChangedFile
) async {
    await fixture.provider.setComparison(
        BridgeEndpointComparison(
            baseEndpoint: fixture.baseEndpoint,
            headEndpoint: fixture.headEndpoint,
            changedFiles: [changedFile]
        )
    )
}

@MainActor
func postRefreshEvent(
    _ fixture: RefreshRevisionFixture,
    path: String,
    batchSeq: UInt64
) async {
    await fixture.controller.handlePaneFilesystemContextEvent(
        .cwdSubtreeChanged(
            context: PaneFilesystemContext(
                paneId: PaneId(existingUUID: fixture.controller.paneId),
                repoId: fixture.headEndpoint.repoId,
                cwd: URL(fileURLWithPath: "/tmp/worktree"),
                worktreeId: fixture.headEndpoint.worktreeId
            ),
            paths: [path],
            batchSeq: batchSeq
        )
    )
}

@MainActor
func expectRefreshPackageState(
    _ fixture: RefreshRevisionFixture,
    itemId: String,
    revision: Int,
    addedItemIds: [String],
    removedItemIds: [String]
) {
    #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == [itemId])
    #expect(fixture.controller.paneState.diff.packageMetadata?.revision == revision)
    #expect(fixture.controller.paneState.diff.packageDelta?.revision == revision)
    #expect(fixture.controller.paneState.diff.packageDelta?.operations.addItems.map(\.itemId) == addedItemIds)
    #expect(fixture.controller.paneState.diff.packageDelta?.operations.removeItems == removedItemIds)
}
