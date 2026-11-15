import Foundation

package enum ResumeUnknownReason: Equatable, Sendable {
    case observationMismatch, changedWhileClosed
    case historyLost, reportRefused, invalidSessionId, unknownProvider, reportsNotRead
}

package enum ResumeEvidence: Equatable, Sendable {
    case interruptedCandidate(ResumeInvocation)
    case knownExited
    case unknown(ResumeUnknownReason)
}

package struct ResumeEvidenceInput: Sendable {
    package let zmxSessionId: ZmxSessionID
    package let coldEndedMain: ColdEndedMain?
    package let evidence: PaneForegroundEvidence?
    package let isSameBoot: Bool
    package let inventory: ZmxSessionInventory

    package init(
        zmxSessionId: ZmxSessionID, coldEndedMain: ColdEndedMain?,
        evidence: PaneForegroundEvidence?, isSameBoot: Bool, inventory: ZmxSessionInventory
    ) {
        self.zmxSessionId = zmxSessionId
        self.coldEndedMain = coldEndedMain
        self.evidence = evidence
        self.isSameBoot = isSameBoot
        self.inventory = inventory
    }
}
