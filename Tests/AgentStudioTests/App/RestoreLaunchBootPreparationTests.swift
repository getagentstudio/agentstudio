import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio

@MainActor
@Suite("Launch-boot App entry and before-mount ordering", .serialized)
struct RestoreLaunchBootPreparationTests {
    @Test("recovered retirement keeps early cleanup ordering and replays only after optional schema preparation")
    func recoveredRetirementFollowsBothInstallsAndOptionalSchema() throws {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let boot = try String(
            contentsOf: root.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8)
        let recovery = try #require(
            boot.range(of: "workspaceSurfaceCoordinator.installUndoJournalRecovery(undoRecovery)"))
        let cleanup = try #require(boot.range(of: "workspaceSurfaceCoordinator.startTerminalSessionCleanup("))
        let evidence = try #require(boot.range(of: "await installRestoreEvidenceOwners("))
        let mounts = try #require(
            boot.range(of: "bootInstallPreparedContentMountOwners(coordinator: workspaceSurfaceCoordinator)"))
        #expect(recovery.lowerBound < cleanup.lowerBound)
        #expect(cleanup.lowerBound < evidence.lowerBound)
        #expect(evidence.lowerBound < mounts.lowerBound)
        let ipc = try String(
            contentsOf: root.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift"), encoding: .utf8)
        let schema = try #require(
            ipc.range(
                of: "guard await AppIPCDeferredInitialization.prepareOptionalSchema(using: workspaceSQLiteDatastore)"))
        let replay = try #require(ipc.range(of: "replayBootRestoreRetirements()"))
        let lifecycle = try #require(ipc.range(of: "startRestoreForegroundLifecycleConsumption()"))
        #expect(schema.lowerBound < replay.lowerBound)
        #expect(replay.lowerBound < lifecycle.lowerBound)
    }

    @Test("the App boot-id seam reads and replaces the real application-local row")
    func appBootIdSeamRecordsPreviousRun() async throws {
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: UUIDv7.generate())
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let first = try await TerminalRestoreLaunchBootPreparation.prepare(datastore: datastore, bootId: { "boot-A" })
        let reboot = try await TerminalRestoreLaunchBootPreparation.prepare(datastore: datastore, bootId: { "boot-B" })
        let same = try await TerminalRestoreLaunchBootPreparation.prepare(datastore: datastore, bootId: { "boot-B" })
        #expect(first.previousBootId == nil)
        #expect(first.isSameBoot)
        #expect(reboot.previousBootId == "boot-A")
        #expect(!reboot.isSameBoot)
        #expect(same.previousBootId == "boot-B")
        #expect(same.isSameBoot)
    }

    @Test("boot preparation awaits the row replacement before canonical hydration can mount panes")
    func bootPreparationAwaitsLaunchBootBeforeMount() throws {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: root.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "private func bootPrepareDatabases() async"))
        let end = try #require(
            source.range(of: "private func bootLoadCanonicalStore() async", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let prepared = try #require(body.range(of: "case .prepared:"))
        let replace = try #require(
            body.range(
                of:
                    "restoreLaunchBoot = try? await TerminalRestoreLaunchBootPreparation.prepare(datastore: sqliteDatastore)"
            ))
        let failed = try #require(body.range(of: "case .failed"))
        #expect(prepared.lowerBound < replace.lowerBound)
        #expect(replace.lowerBound < failed.lowerBound)
        #expect(WorkspaceBootSequence.presentationPrerequisiteSteps.first == .prepareDatabases)
        #expect(WorkspaceBootSequence.presentationPrerequisiteSteps.dropFirst().first == .loadCanonicalStore)
    }
}
