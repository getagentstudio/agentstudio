import Foundation

@testable import AgentStudioBridge

@MainActor
enum BridgeProductWebKitRefreshCapture {
    static func snapshot(_ controller: BridgePaneController) -> String {
        let coordinator = controller.refreshAdmissionCoordinator
        let snapshot = coordinator.diagnosticSnapshot
        let activePass =
            snapshot.activeRefreshPass.map {
                "lanes=\($0.lanes.map(\.rawValue).sorted()),id=\($0.id.uuidString),"
                    + "batch=\($0.latestBatchSequence),operation=\($0.operationCorrelationID)"
            } ?? "nil"
        let dirtyFact =
            snapshot.dirtyFact.map {
                "fileLane=\($0.fileChangeset != nil || $0.latestFileStatus != nil),"
                    + "reviewLane=\($0.requiresReviewRefresh),batch=\($0.latestBatchSequence),generation=\($0.generation)"
            } ?? "nil"
        return "activity=\(snapshot.activity),activeRefreshPass=\(activePass),dirtyFact=\(dirtyFact),"
            + "filePassActive=\(coordinator.isRefreshLaneActive(.file)),"
            + "reviewPassActive=\(coordinator.isRefreshLaneActive(.review)),"
            + "fileFailure=\(String(describing: snapshot.fileRefreshFailure)),"
            + "fileOperation=\(controller.worktreeRefreshDriver.hasActiveFileOperation),"
            + "fileRecovery=\(controller.worktreeRefreshDriver.hasPendingFileStreamRecovery),"
            + "reviewShown=\(controller.isReviewShownByPage),"
            + "reviewLoad=\(controller.hasCurrentReviewPackageLoad),"
            + "pendingExplicit=\(controller.hasPendingOrResumingExplicitReviewCommand),"
            + "pendingComparison=\(String(describing: controller.pendingComparisonReviewGeneration)),"
            + "activeReviewRefreshTaskPresent=\(controller.activeReviewRefreshTask != nil),"
            + "refreshPassCount=\(snapshot.refreshPassCount)"
    }

    static func checkpoint(_ name: String, controller: BridgePaneController) {
        emit(name, snapshot: snapshot(controller))
    }

    nonisolated static func emit(_ name: String, snapshot: String = "not_sampled") {
        print("refresh-capture monotonic=\(DispatchTime.now().uptimeNanoseconds) event=\(name) snapshot=\(snapshot)")
    }
}
