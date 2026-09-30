struct BadAdHocContinuationWait {
    var parkedWaiters: [CheckedContinuation<(String, Int), Never>] = []

    func suspendAtContinuation() async {
        await withCheckedContinuation { _ in }
    }
}
