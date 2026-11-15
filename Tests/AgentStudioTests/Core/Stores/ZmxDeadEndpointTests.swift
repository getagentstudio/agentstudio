import Darwin
import Testing

@testable import AgentStudioCore

@Suite("Dead zmx endpoint evidence")
struct ZmxDeadEndpointTests {
    @Test("only a refused socket with no bound holder is dead", arguments: 0..<4)
    func allEvidenceIsRequired(scenario: Int) throws {
        let process = ZmxIncompatibleSessionStop.ProcessEvidence(
            incarnation: .init(pid: 42, startSeconds: 1, startMicroseconds: 0), parentPID: 1, groupPID: 42)
        let dead = try ZmxIncompatibleSessionStop.endpointIsDead(
            isSocket: scenario != 0, connectionRefused: { scenario != 1 },
            processInspections: { [.success(process)] }, inspectBoundSocket: { _ in .success(scenario == 2) })
        #expect(dead == (scenario == 3))
    }

    @Test("inspection denial cannot prove endpoint death", arguments: [false, true])
    func inspectionFailureIsAmbiguous(failsProcess: Bool) {
        let process = ZmxIncompatibleSessionStop.ProcessEvidence(
            incarnation: .init(pid: 42, startSeconds: 1, startMicroseconds: 0), parentPID: 1, groupPID: 42)
        #expect(throws: ZmxSessionControlFailure.processUnverifiable) {
            _ = try ZmxIncompatibleSessionStop.endpointIsDead(
                isSocket: true, connectionRefused: { true },
                processInspections: { failsProcess ? [.failure(POSIXErrorNumber(EACCES))] : [.success(process)] },
                inspectBoundSocket: { _ in .failure(POSIXErrorNumber(EPERM)) })
        }
    }

    @Test("an exited process can be excluded from the bound-holder census")
    func exitedProcessIsNotAHolder() throws {
        #expect(
            try ZmxIncompatibleSessionStop.endpointIsDead(
                isSocket: true, connectionRefused: { true },
                processInspections: { [.failure(POSIXErrorNumber(ESRCH))] },
                inspectBoundSocket: { _ in .success(true) }))
    }
}
