import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@testable import AgentStudioSessions

enum ResumeEvidenceCase: CaseIterable { case noEvidence, look, end, otherEnd, otherStart, historyLost, refused }
enum ResumeDeathCase: CaseIterable { case absent, refused, alive, unresponsive, unavailable, malformedIdentity }

struct ResumeResolverFixture {
    let paneID = UUIDv7.generate()
    let generation = UUIDv7.generate()
    let sessionID = UUIDv7.generate().uuidString.lowercased()
    let zmxID = ZmxSessionID.generateUUIDv7()
    let observerID = UUIDv7.generate()
    let provider: String

    func input(
        mainExists: Bool = true, validID: Bool = true, generationMatches: Bool = true,
        sameBoot: Bool = false, death: ResumeDeathCase = .absent,
        evidence: ResumeEvidenceCase = .look, program: ForegroundProgram = .codex
    ) throws -> ResumeEvidenceInput {
        let identity = try ZmxSessionIdentity(
            version: 1, bootID: sameBoot ? "boot-current" : "boot-previous",
            daemon: .init(pid: 2111, startSeconds: 1, startMicroseconds: 1),
            terminalLeader: .init(pid: 2112, startSeconds: 1, startMicroseconds: 2),
            processGroupID: 2112, sessionCreatedAt: 1
        ).encoded()
        let look = PaneForegroundLook(
            paneId: paneID, zmxSessionId: zmxID,
            sessionIdentity: death == .malformedIdentity ? Data("bad identity".utf8) : identity,
            bindingGenerationId: generationMatches ? generation : UUIDv7.generate(),
            program: program, observerLaunchId: observerID, sequence: 1, observedAt: Date(timeIntervalSince1970: 1))
        let foreground: PaneForegroundEvidence?
        switch evidence {
        case .noEvidence: foreground = nil
        case .look: foreground = look.evidence
        default:
            let value: ForegroundEvidence
            switch evidence {
            case .end: value = .reportedEnd
            case .otherEnd: value = .reportedOtherSessionEnd(.init(provider: .codex, conversationId: "another-id"))
            case .otherStart: value = .reportedOtherStart(.init(provider: .codex, conversationId: "another-id"))
            case .historyLost: value = .reportsUnreadable(.historyLost)
            case .refused: value = .reportsUnreadable(.rowRefused)
            case .noEvidence, .look: preconditionFailure("handled above")
            }
            foreground = .init(
                paneId: paneID, bindingGenerationId: generation, observerLaunchId: observerID,
                sequence: 2, observedAt: Date(timeIntervalSince1970: 2), value: value)
        }
        let inventory: ZmxSessionInventory
        switch death {
        case .absent, .malformedIdentity: inventory = .complete([:])
        case .refused: inventory = .complete([zmxID: .refused])
        case .alive: inventory = .complete([zmxID: .alive(wrapperPid: 2111)])
        case .unresponsive: inventory = .complete([zmxID: .unresponsive])
        case .unavailable: inventory = .unavailable(.timedOut)
        }
        return .init(
            paneId: paneID, zmxSessionId: zmxID,
            coldEndedMain: mainExists
                ? .init(
                    bindingGenerationId: generation, providerIdentifier: provider,
                    providerConversationId: validID ? sessionID : "--last") : nil,
            evidence: foreground, preRestoreLook: look, launchBootId: "boot-current", inventory: inventory)
    }
}
