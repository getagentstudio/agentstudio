import AgentStudioAppIPC
import AgentStudioProgrammaticControl
import Foundation

struct FakeQueryPort: AppIPCQueryPort {
    let runtimeId: UUID
    let panes: [IPCPaneSummary]

    nonisolated init(
        runtimeId: UUID = UUID(),
        panes: [IPCPaneSummary] = []
    ) {
        self.runtimeId = runtimeId
        self.panes = panes
    }

    func systemIdentify() throws -> IPCSystemIdentifyResult {
        IPCSystemIdentifyResult(runtimeId: runtimeId, accessMode: .agentStudioOnly, appVersion: "test")
    }

    func systemVersion() throws -> IPCSystemVersionResult {
        IPCSystemVersionResult(appVersion: "test")
    }

    func listWindows() throws -> IPCWindowListResult {
        IPCWindowListResult(windows: [])
    }

    func currentWindow() throws -> IPCCurrentWindowResult {
        throw AppIPCQueryError(reason: .noActiveWindow)
    }

    func listWorkspaces() throws -> IPCWorkspaceListResult {
        IPCWorkspaceListResult(workspaces: [])
    }

    func currentWorkspace() throws -> IPCCurrentWorkspaceResult {
        throw AppIPCQueryError(reason: .noActiveWindow)
    }

    func listPanes() throws -> IPCPaneListResult {
        IPCPaneListResult(panes: panes)
    }

    func currentPane() throws -> IPCPaneSnapshotResult {
        throw AppIPCQueryError(reason: .noActiveWindow)
    }

    func snapshotPane(_ paneId: UUID, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCPaneSnapshotResult {
        guard let pane = panes.first(where: { $0.id == paneId }) else {
            throw AppIPCQueryError(reason: .targetNotFound)
        }
        return makePaneSnapshotResult(pane: pane, paneCount: panes.count)
    }
}

final class RecordingSnapshotQueryPort: AppIPCQueryPort, @unchecked Sendable {
    let runtimeId: UUID
    let panes: [IPCPaneSummary]
    private let lock = NSLock()
    nonisolated(unsafe) private var snapshotPaneIdsStorage: [UUID] = []

    nonisolated init(
        runtimeId: UUID = UUID(),
        panes: [IPCPaneSummary]
    ) {
        self.runtimeId = runtimeId
        self.panes = panes
    }

    nonisolated var snapshotPaneIds: [UUID] {
        lock.withLock {
            snapshotPaneIdsStorage
        }
    }

    func systemIdentify() throws -> IPCSystemIdentifyResult {
        IPCSystemIdentifyResult(runtimeId: runtimeId, accessMode: .agentStudioOnly, appVersion: "test")
    }

    func systemVersion() throws -> IPCSystemVersionResult {
        IPCSystemVersionResult(appVersion: "test")
    }

    func listWindows() throws -> IPCWindowListResult {
        IPCWindowListResult(windows: [])
    }

    func currentWindow() throws -> IPCCurrentWindowResult {
        throw AppIPCQueryError(reason: .noActiveWindow)
    }

    func listWorkspaces() throws -> IPCWorkspaceListResult {
        IPCWorkspaceListResult(workspaces: [])
    }

    func currentWorkspace() throws -> IPCCurrentWorkspaceResult {
        throw AppIPCQueryError(reason: .noActiveWindow)
    }

    func listPanes() throws -> IPCPaneListResult {
        IPCPaneListResult(panes: panes)
    }

    func currentPane() throws -> IPCPaneSnapshotResult {
        guard let pane = panes.first else {
            throw AppIPCQueryError(reason: .targetNotFound)
        }
        return makePaneSnapshotResult(pane: pane, paneCount: panes.count)
    }

    func snapshotPane(_ paneId: UUID, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCPaneSnapshotResult {
        lock.withLock {
            snapshotPaneIdsStorage.append(paneId)
        }
        guard let pane = panes.first(where: { $0.id == paneId }) else {
            throw AppIPCQueryError(reason: .targetNotFound)
        }
        return makePaneSnapshotResult(pane: pane, paneCount: panes.count)
    }
}
