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

    @Test func mismatchedExpectation() {
        #expect(condition)
        guard otherCondition else { return }
    }

    @Test func nestedIfReturn() {
        guard condition else {
            if shouldReturn { return }
        }
    }

    @Test func nestedSwitchReturn() {
        guard condition else {
            switch state {
            case .bad: return
            default: break
            }
        }
    }
}
