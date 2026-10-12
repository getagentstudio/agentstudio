import Testing

struct GoodSilentTestReturns {
    @Test func recordsIssue() {
        guard condition else {
            Issue.record("setup failed")
            return
        }
    }

    @Test func recordsExpectation() {
        guard condition else {
            #expect(false, "setup failed")
            return
        }
    }

    @Test func throwsFailure() throws {
        guard condition else {
            throw TestError.failed
        }
    }

    @Test func exactExpectationMatch() {
        #expect(condition)
        guard condition else { return }
        #expect(otherCondition, "message form")
        guard otherCondition else { return }
    }

    @Test func nestedSignalDominatesReturn() {
        guard condition else {
            if shouldReturn {
                Issue.record("setup failed")
                return
            }
        }
    }

    @Test func nestedFunctionIsIgnored() {
        func helper() {
            guard condition else { return }
        }
        helper()
    }

    @Test func closureIsIgnored() {
        let callback = {
            guard condition else { return }
        }
        callback()
    }

    private func helper() {
        guard condition else { return }
    }
}

private enum TestError: Error {
    case failed
}
