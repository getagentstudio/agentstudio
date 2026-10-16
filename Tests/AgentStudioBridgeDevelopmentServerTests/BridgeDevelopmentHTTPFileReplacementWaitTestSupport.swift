import AgentStudioTestHarness

@testable import AgentStudioBridge

/// Diagnostic lifetime of the already accepted File recovery, not a second wait.
struct HTTPFileReplacementWait {
    private enum ExpectedSide: String {
        case begin = "BEGIN"
        case complete = "COMPLETE"
    }

    private let staleBegin: BridgeProductBatchBeginFrame
    private let log: ExpectationLog
    private var expectedSide = ExpectedSide.begin
    private var pendingIdentifier: String?

    init(staleBegin: BridgeProductBatchBeginFrame, log: ExpectationLog = .environment) {
        self.staleBegin = staleBegin
        self.log = log
        register()
    }

    mutating func receivedBegin() {
        settle(expectedSide == .begin ? .matched : .ended)
        expectedSide = .complete
        register()
    }

    mutating func rejectedBegin() {
        guard expectedSide == .complete else { return }
        settle(.ended)
        expectedSide = .begin
        register()
    }

    mutating func settle(_ outcome: ExpectationLog.Settlement) {
        guard let pendingIdentifier else { return }
        log.settled(pendingIdentifier, outcome: outcome)
        self.pendingIdentifier = nil
    }

    private mutating func register() {
        let identity = staleBegin.identity
        pendingIdentifier = log.expecting(
            expectedCase:
                "File recovery replacement \(expectedSide.rawValue) staleTarget=\(staleBegin.targetRevision) domain=\(identity.domain) incarnation=\(identity.incarnation)",
            scope:
                "subscription=\(identity.subscriptionId) handle=\(identity.handle) scopeRevision=\(identity.scopeRevision)",
            test: "\(#fileID) nextHTTPFileBatchSnapshot",
            callSite: "\(#fileID):\(#line) \(#function)"
        )
    }
}
