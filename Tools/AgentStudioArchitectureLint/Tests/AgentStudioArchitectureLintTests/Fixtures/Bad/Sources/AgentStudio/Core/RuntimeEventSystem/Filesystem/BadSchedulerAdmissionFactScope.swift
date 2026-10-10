typealias WatchedFolderScanValidationScope = String
enum WatchedFolderScanSchedulerFact { case shutdownAwaitingAdmission }
typealias WatchedFolderScanSchedulerFactSink =
    (WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact) -> Void

struct InFlightValidationAdmission {
    let scope: WatchedFolderScanValidationScope
    let task: Task<Void, Never>
}

actor WatchedFolderScanScheduler {
    let factSink: WatchedFolderScanSchedulerFactSink?
    var admissions: [String: InFlightValidationAdmission] = [:]

    func submitValidation(_ requestID: String) {
        let scope = WatchedFolderScanValidationScope()
        let task = Task {}
        admissions[requestID] = InFlightValidationAdmission(scope: scope, task: task)
        submitToProductionExecutor(requestID)
    }

    private func submitToProductionExecutor(_ requestID: String) {}
}
