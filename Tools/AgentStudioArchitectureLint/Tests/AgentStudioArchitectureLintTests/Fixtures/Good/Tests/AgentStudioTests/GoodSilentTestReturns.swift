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

    private func helper() {
        guard condition else { return }
    }
}

private enum TestError: Error {
    case failed
}
