import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions
@testable import AgentStudioTestSupport

@Suite("Restore resume decision cost")
struct RestoreResumeCostTests {
    @Test("the real no-main verdict records its synchronous off-main decision")
    func resumeDecisionRecordsOffMainSlice() async throws {
        let trace = RestoreCostTraceTestFixture()
        defer { trace.cleanup() }
        do {
            let input = ResumeEvidenceInput(
                zmxSessionId: .generateUUIDv7(), coldEndedMain: nil,
                evidence: nil, isSameBoot: false, inventory: .complete([:]))
            let result = await SessionsResumeResolver(performanceTraceRecorder: trace.recorder).resumeEvidence(
                for: input)
            #expect(result == .knownExited)
            let records = try await trace.finish()
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.body == "performance.restore.resume.decide")
            #expect(record.attributes.mainThreadExecutions == 0)
            #expect(record.attributes.mainThreadMilliseconds == 0)
        } catch {
            try? await trace.recorder.drain()
            throw error
        }
    }
}
