import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

struct BridgeProductWebKitCatchUpOperation: Hashable, Sendable {
    let lane: BridgePaneRefreshLane
    let operationId: String
}

enum BridgeProductWebKitCatchUpFact: Sendable {
    case reserved
    case terminal(result: String)
}

struct BridgeProductWebKitCatchUpTerminalObservation: Sendable {
    let operation: BridgeProductWebKitCatchUpOperation
    let result: String
}

struct BridgeProductWebKitCatchUpTerminalExpectation: Sendable {
    let batchSequence: UInt64
    let lanes: Set<BridgePaneRefreshLane>
    let recorder: FactRecorder<BridgeProductWebKitCatchUpOperation, BridgeProductWebKitCatchUpFact>

    init(dirtyFact: BridgePaneRefreshDirtyFact?) {
        batchSequence = dirtyFact?.latestBatchSequence ?? 0
        var dirtyLanes: Set<BridgePaneRefreshLane> = []
        if dirtyFact?.fileChangeset != nil || dirtyFact?.latestFileStatus != nil { dirtyLanes.insert(.file) }
        if dirtyFact?.requiresReviewRefresh == true { dirtyLanes.insert(.review) }
        lanes = dirtyLanes
        recorder = FactRecorder(
            vocabulary: .init(
                describeScope: { "\($0.lane.rawValue) catch-up \($0.operationId)" },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in if case .terminal = fact { true } else { false } }
            )
        )
    }

    func wait() async throws -> [BridgeProductWebKitCatchUpTerminalObservation] {
        var terminals: [BridgeProductWebKitCatchUpTerminalObservation] = []
        for lane in lanes.sorted(by: { $0.rawValue < $1.rawValue }) {
            let operation = try await recorder.expectNextOperation(
                matching: { $0.lane == lane },
                opening: { if case .reserved = $0 { true } else { false } },
                "\(lane.rawValue) foreground catch-up reservation for dirty batch \(batchSequence)"
            )
            _ = try await recorder.expectNext(
                in: operation, where: { if case .reserved = $0 { true } else { false } },
                "correlated \(lane.rawValue) catch-up reservation"
            )
            let terminal = try await recorder.expectNext(
                in: operation, where: { if case .terminal = $0 { true } else { false } },
                "correlated \(lane.rawValue) catch-up terminal for dirty batch \(batchSequence)"
            )
            if case .terminal(let result) = terminal {
                terminals.append(.init(operation: operation, result: result))
            }
        }
        return terminals
    }

    func describeUnsettledCatchUp(
        snapshot: BridgePaneRefreshAdmissionSnapshot,
        reviewTaskPresent: Bool
    ) -> String {
        let activePass =
            snapshot.activeRefreshPass.map {
                "lanes=\($0.lanes.map(\.rawValue).sorted()),id=\($0.id.uuidString)"
            } ?? "nil"
        let dirtyFact =
            snapshot.dirtyFact.map {
                "fileLane=\($0.fileChangeset != nil || $0.latestFileStatus != nil),"
                    + "reviewLane=\($0.requiresReviewRefresh),batch=\($0.latestBatchSequence),"
                    + "generation=\($0.generation)"
            } ?? "nil"
        return "foreground catch-up did not settle (activity=\(snapshot.activity),"
            + "activeRefreshPass=\(activePass),dirtyFact=\(dirtyFact),"
            + "activeReviewRefreshTaskPresent=\(reviewTaskPresent))"
    }
}
