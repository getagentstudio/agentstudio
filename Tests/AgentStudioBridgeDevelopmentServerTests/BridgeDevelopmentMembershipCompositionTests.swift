import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridgeDevelopmentServer
@testable import AgentStudioCore

@MainActor
@Suite("Bridge development membership composition", .serialized)
struct BridgeDevelopmentMembershipCompositionTests {
    @Test("Development composition publishes the exact seeded and restored pane through its own directory")
    func seededAndRestoredCompositionPublishesCanonicalMembership() async throws {
        let paneId = PaneId.generateUUIDv7()
        let root = FileManager.default.temporaryDirectory.appending(path: "membership-development-\(UUIDv7.generate())")
        let dataRoot = root.appending(path: "data")
        let worktreeRoot = root.appending(path: "repository")
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try BridgeDevelopmentServerConfiguration(
            dataRoot: dataRoot, paneID: paneId.uuid, port: 43_871,
            seedContributionTarget: .ref(name: "refs/heads/persisted-membership"), seedWorktreeRoot: worktreeRoot)
        let first = try await BridgeDevelopmentServerCoreComposition.prepare(configuration: configuration)
        let initial: PaneContextMembershipView
        let initialSource = first.productSource
        do {
            initial = try #require(first.paneContextMembershipDirectory.view(for: paneId))
            #expect(initial.sources == [paneId])
            #expect(first.paneContextMembershipDirectory.ownerPaneId(for: paneId) == nil)
            #expect(
                first.paneContextMembershipDirectory.contains(paneID: paneId.uuid, inWorkspace: initial.workspaceId))
            #expect(initialSource.paneID == paneId.uuid)
            try await first.shutdown()
        } catch {
            try? await first.shutdown()
            throw error
        }
        let reload = try BridgeDevelopmentServerConfiguration(
            dataRoot: dataRoot, paneID: paneId.uuid, port: 43_872,
            seedContributionTarget: .ref(name: "refs/heads/must-not-reseed"), seedWorktreeRoot: worktreeRoot)
        let restored = try await BridgeDevelopmentServerCoreComposition.prepare(configuration: reload)
        do {
            let current = try #require(restored.paneContextMembershipDirectory.view(for: paneId))
            #expect(current.workspaceId == initial.workspaceId)
            #expect(current.sources == [paneId])
            #expect(restored.paneContextMembershipDirectory.ownerPaneId(for: paneId) == nil)
            #expect(restored.productSource.paneID == initialSource.paneID)
            #expect(restored.productSource.repoID == initialSource.repoID)
            #expect(restored.productSource.worktreeID == initialSource.worktreeID)
            #expect(restored.productSource.paneState == initialSource.paneState)
            #expect(restored.paneContextMembershipDirectory.currentOwners().filter { $0.paneId == paneId }.count == 1)
            #expect(
                restored.paneContextMembershipDirectory.contains(paneID: paneId.uuid, inWorkspace: current.workspaceId))
            try await restored.shutdown()
        } catch {
            try? await restored.shutdown()
            throw error
        }
    }
}
