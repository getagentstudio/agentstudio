import AgentStudioCore
import Foundation

package struct ForegroundSnapshot: Equatable, Sendable {
    package let sessionIdentity: Data
    package let foregroundProcess: ProcessIncarnation?
    package let program: ForegroundProgram
}

package protocol TerminalForegroundProbing: Sendable {
    func probeForeground(of sessions: [ZmxSessionID]) async throws -> [ZmxSessionID: ForegroundSnapshot]
}

package enum ForegroundLookTrigger: Sendable {
    case bindingChanged, agentMessage, appQuitting, relaunched
    case outputBegan(burstWindowId: UUID)
    case outputSettled(burstWindowId: UUID)
}

package struct CurrentExitWatch: Equatable, Sendable {
    package let watchId: UUID
    package let incarnation: ProcessIncarnation
    package let bindingGenerationId: UUID?
}

package struct ForegroundObserverPolicy: Sendable {
    package let lookSettleDelay: Duration
    package let lookMaxDelay: Duration
    package let quitLookDeadline: Duration

    package init(
        lookSettleDelay: Duration, lookMaxDelay: Duration, quitLookDeadline: Duration
    ) {
        self.lookSettleDelay = lookSettleDelay
        self.lookMaxDelay = lookMaxDelay
        self.quitLookDeadline = quitLookDeadline
    }
}

package struct ForegroundObserverFactScope: Hashable, Sendable {
    package let paneId: UUID
    package let operationId: UUID
}

package enum ForegroundObserverFact: Equatable, Sendable {
    case scheduled
    case snapshotStarted(sequence: UInt64)
    case observation(ForegroundEvidenceAdmission)
    case watchRegistered(watchId: UUID)
    case watchUnavailable(ProcessExitWatchFailure)
    case staleWatchDropped(watchId: UUID)
    case closed(ForegroundObserverClose)
}

package enum ForegroundObserverClose: Equatable, Sendable {
    case scheduled, looked, retired, quit, quitDeadline
}
