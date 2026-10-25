import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@testable import AgentStudioSessions

enum ResumeEvidenceCase: CaseIterable { case noEvidence, end, otherEnd, otherStart, historyLost, refused }
enum ResumeDeathCase: CaseIterable { case absent, refused, alive, unresponsive, unavailable }

struct ResumeResolverFixture {
    let paneID = UUIDv7.generate()
    let generation = UUIDv7.generate()
    let sessionID = UUIDv7.generate().uuidString.lowercased()
    let zmxID = ZmxSessionID.generateUUIDv7()
    let provider: String

    func input(
        mainExists: Bool = true, validID: Bool = true, sameBoot: Bool = false,
        death: ResumeDeathCase = .absent, evidence: ResumeEvidenceCase = .noEvidence
    ) throws -> ResumeEvidenceInput {
        let reported: ForegroundEvidence?
        switch evidence {
        case .noEvidence: reported = nil
        case .end: reported = .reportedEnd
        case .otherEnd: reported = .reportedOtherSessionEnd(.init(provider: .codex, conversationId: "another-id"))
        case .otherStart: reported = .reportedOtherStart(.init(provider: .codex, conversationId: "another-id"))
        case .historyLost: reported = .reportsUnreadable(.historyLost)
        case .refused: reported = .reportsUnreadable(.rowRefused)
        }
        let foreground = reported.map {
            PaneForegroundEvidence(
                paneId: paneID, bindingGenerationId: generation, observerLaunchId: UUIDv7.generate(),
                sequence: 2, observedAt: Date(timeIntervalSince1970: 2), value: $0)
        }
        let inventory: ZmxSessionInventory
        switch death {
        case .absent: inventory = .complete([:])
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
            evidence: foreground, isSameBoot: sameBoot, inventory: inventory)
    }
}
