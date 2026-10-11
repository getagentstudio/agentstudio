import Testing

struct BadSilentTestReturns {
    @Test func boolWait() async {
        guard await waitForEvent() else { return }
    }

    @Test func caseMatch() {
        guard case .ready = state else { return }
    }

    @Test func optionalBinding() {
        guard let value else { return }
        consume(value)
    }
}
