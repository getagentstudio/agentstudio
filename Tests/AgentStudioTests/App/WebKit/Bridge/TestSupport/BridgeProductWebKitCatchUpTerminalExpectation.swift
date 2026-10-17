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

struct BridgeProductWebKitActiveViewerModeIdentity: Equatable, Sendable {
    let sessionId: String
    let sequence: Int
}

struct BridgeProductWebKitCatchUpTerminalExpectation: Sendable {
    let batchSequence: UInt64
    let dirtyGeneration: UInt64?
    let lanes: Set<BridgePaneRefreshLane>
    let reviewModeIdentity: BridgeProductWebKitActiveViewerModeIdentity?
    let recorder: FactRecorder<BridgeProductWebKitCatchUpOperation, BridgeProductWebKitCatchUpFact>

    init(
        dirtyFact: BridgePaneRefreshDirtyFact?,
        reviewModeIdentity: BridgeProductWebKitActiveViewerModeIdentity? = nil
    ) {
        var dirtyLanes: Set<BridgePaneRefreshLane> = []
        if dirtyFact?.fileChangeset != nil || dirtyFact?.latestFileStatus != nil { dirtyLanes.insert(.file) }
        if dirtyFact?.requiresReviewRefresh == true { dirtyLanes.insert(.review) }
        self.init(
            lanes: dirtyLanes,
            batchSequence: dirtyFact?.latestBatchSequence ?? 0,
            dirtyGeneration: dirtyFact?.generation,
            reviewModeIdentity: reviewModeIdentity
        )
    }

    init(
        lanes: Set<BridgePaneRefreshLane>,
        batchSequence: UInt64,
        dirtyGeneration: UInt64? = nil,
        reviewModeIdentity: BridgeProductWebKitActiveViewerModeIdentity? = nil
    ) {
        self.batchSequence = batchSequence
        self.dirtyGeneration = dirtyGeneration
        self.lanes = lanes
        self.reviewModeIdentity = reviewModeIdentity
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
            while currentLaneNeedsAnotherAttempt(terminals, lane: lane) {
                let operation = try await recorder.expectNextOperation(
                    matching: { $0.lane == lane },
                    opening: { if case .reserved = $0 { true } else { false } },
                    "\(lane.rawValue) catch-up attempt for batch \(batchSequence), "
                        + "generation \(String(describing: dirtyGeneration))"
                )
                _ = try await recorder.expectNext(
                    in: operation, where: { if case .reserved = $0 { true } else { false } },
                    "correlated \(lane.rawValue) catch-up reservation \(operation.operationId)"
                )
                let terminal = try await recorder.expectNext(
                    in: operation, where: { if case .terminal = $0 { true } else { false } },
                    "correlated \(lane.rawValue) catch-up terminal \(operation.operationId)"
                )
                if case .terminal(let result) = terminal {
                    terminals.append(.init(operation: operation, result: result))
                    // Only a Review-mode-bound obligation can pass a superseded predecessor and await
                    // the current attempt. Unbound callers retain their original first-terminal contract.
                    guard reviewModeIdentity != nil,
                        result == "stale" || result == "cancelled"
                    else {
                        break
                    }
                }
            }
        }
        return terminals
    }

    func currentAttemptsSucceeded(
        _ observations: [BridgeProductWebKitCatchUpTerminalObservation]
    ) -> Bool {
        lanes.allSatisfy { lane in
            observations.last(where: { $0.operation.lane == lane })?.result == "success"
        }
    }

    private func currentLaneNeedsAnotherAttempt(
        _ observations: [BridgeProductWebKitCatchUpTerminalObservation],
        lane: BridgePaneRefreshLane
    ) -> Bool {
        guard let latestResult = observations.last(where: { $0.operation.lane == lane })?.result else {
            return true
        }
        return reviewModeIdentity != nil && (latestResult == "stale" || latestResult == "cancelled")
    }

    func describeUnsettledCatchUp(
        snapshot: BridgePaneRefreshAdmissionSnapshot,
        reviewTaskPresent: Bool,
        terminalResultsDescription: String
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
        return "foreground catch-up obligation did not settle (batch=\(batchSequence),"
            + "dirtyGeneration=\(String(describing: dirtyGeneration)),"
            + "reviewModeSession=\(reviewModeIdentity?.sessionId ?? "nil"),"
            + "reviewModeSequence=\(reviewModeIdentity.map { String($0.sequence) } ?? "nil"),"
            + "activity=\(snapshot.activity),"
            + "activeRefreshPass=\(activePass),dirtyFact=\(dirtyFact),"
            + "activeReviewRefreshTaskPresent=\(reviewTaskPresent),terminals=[\(terminalResultsDescription)])"
    }

    func describeTerminalResults(
        _ observations: [BridgeProductWebKitCatchUpTerminalObservation],
        snapshot: BridgePaneRefreshAdmissionSnapshot,
        reviewAttemptDescription: String
    ) -> String {
        let currentAttempts = lanes.sorted(by: { $0.rawValue < $1.rawValue }).map { lane in
            let latestObservation = observations.last(where: { $0.operation.lane == lane })
            let operationId = latestObservation?.operation.operationId ?? "missing"
            let result = latestObservation?.result ?? "missing"
            return "\(lane.rawValue)=\(operationId):\(result)"
        }.joined(separator: ",")
        let modeIdentity =
            reviewModeIdentity.map {
                "\($0.sessionId)@\($0.sequence)"
            } ?? "unbound"
        let attempts = observations.map { observation in
            let nativeReason =
                observation.operation.lane == .file
                ? snapshot.fileRefreshFailure?.failureKind.rawValue ?? "none"
                : reviewAttemptDescription
            return "lane=\(observation.operation.lane.rawValue),operationId=\(observation.operation.operationId),"
                + "result=\(observation.result),terminalReason=not-recorded,currentNativeReason=\(nativeReason)"
        }.joined(separator: "; ")
        return "obligation=batch:\(batchSequence),generation:\(String(describing: dirtyGeneration)),"
            + "reviewMode:\(modeIdentity),currentAttempts=[\(currentAttempts)],attempts=[\(attempts)]"
    }
}
