import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("SR11/SR12 cold verdict input product")
struct SessionResumeResolverTests {
    @Test(arguments: ["claude-code", "codex", "unrecognized-provider"])
    func exhaustiveResumeInputProduct(provider: String) async throws {
        let fixture = ResumeResolverFixture(provider: provider)
        var rows = 0
        for mainExists in [false, true] {
            for validID in [false, true] {
                for generationMatches in [false, true] {
                    for sameBoot in [false, true] {
                        for death in ResumeDeathCase.allCases {
                            for evidence in ResumeEvidenceCase.allCases {
                                for program in [ForegroundProgram.shell, .claudeCode, .codex, .other, .unknown] {
                                    let input = try fixture.input(
                                        mainExists: mainExists, validID: validID, generationMatches: generationMatches,
                                        sameBoot: sameBoot, death: death, evidence: evidence, program: program)
                                    let result = await SessionsResumeResolver().resumeEvidence(for: input)
                                    // Spec SR12: reported end wins; an already-ended/no-main pane with no report exits.
                                    let exits =
                                        evidence == .end
                                        || (!mainExists && (evidence == .noEvidence || evidence == .look))
                                    // Spec SR11: a cold-ended main + its provider in the pre-restore foreground,
                                    // exact valid id, correct generation and proof that its daemon is gone.
                                    let providerMatches =
                                        (provider == "codex" && program == .codex)
                                        || (provider == "claude-code" && program == .claudeCode)
                                    let interrupted =
                                        mainExists && validID && generationMatches && evidence == .look
                                        && providerMatches && death != .malformedIdentity
                                        && (!sameBoot || death == .absent || death == .refused)
                                    if exits {
                                        #expect(result == .knownExited)
                                    } else if interrupted {
                                        guard case .interruptedCandidate(let invocation) = result else {
                                            Issue.record("SR11 positive row refused: \(provider), \(death)")
                                            return
                                        }
                                        #expect(invocation.sessionId.rawValue == fixture.sessionID)
                                    } else {
                                        guard case .unknown = result else {
                                            Issue.record(
                                                "SR12 veto row resumed or exited: \(provider), \(evidence), \(death)")
                                            return
                                        }
                                    }
                                    rows += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(rows == 3360)
    }

    @Test("reported reasons and raw invalid provider/id remain distinguishable")
    func reportedEvidenceReasonsAndRawValidation() async throws {
        let fixture = ResumeResolverFixture(provider: "codex")
        for (kind, reason) in [
            (ResumeEvidenceCase.otherStart, ResumeUnknownReason.changedWhileClosed),
            (.otherEnd, .changedWhileClosed), (.historyLost, .historyLost), (.refused, .reportRefused),
        ] {
            let input = try fixture.input(evidence: kind)
            #expect(await SessionsResumeResolver().resumeEvidence(for: input) == .unknown(reason))
        }
        #expect(
            await SessionsResumeResolver().resumeEvidence(for: try fixture.input(validID: false))
                == .unknown(.invalidSessionId))
        let unknown = ResumeResolverFixture(provider: "cursor")
        #expect(await SessionsResumeResolver().resumeEvidence(for: try unknown.input()) == .unknown(.unknownProvider))
    }
}
