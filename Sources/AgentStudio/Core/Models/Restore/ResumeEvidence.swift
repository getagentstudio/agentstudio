import Foundation

package enum ResumeUnknownReason: Equatable, Sendable {
    case noObservation, observationMismatch, programNotAgent, changedWhileClosed
    case historyLost, reportRefused, invalidSessionId, unknownProvider, reportsNotRead
}

package enum ResumeEvidence: Equatable, Sendable {
    case interruptedCandidate(ResumeInvocation)
    case knownExited
    case unknown(ResumeUnknownReason)
}

package struct ResumeEvidenceInput: Sendable {
    package let paneId: UUID
    package let zmxSessionId: ZmxSessionID
    package let coldEndedMain: ColdEndedMain?
    package let evidence: ForegroundEvidence?
    package let preRestoreLook: PaneForegroundLook?
    package let launchBootId: String
    package let inventory: ZmxSessionInventory

    package init(
        paneId: UUID, zmxSessionId: ZmxSessionID, coldEndedMain: ColdEndedMain?,
        evidence: ForegroundEvidence?, preRestoreLook: PaneForegroundLook?,
        launchBootId: String, inventory: ZmxSessionInventory
    ) {
        self.paneId = paneId
        self.zmxSessionId = zmxSessionId
        self.coldEndedMain = coldEndedMain
        self.evidence = evidence
        self.preRestoreLook = preRestoreLook
        self.launchBootId = launchBootId
        self.inventory = inventory
    }
}
