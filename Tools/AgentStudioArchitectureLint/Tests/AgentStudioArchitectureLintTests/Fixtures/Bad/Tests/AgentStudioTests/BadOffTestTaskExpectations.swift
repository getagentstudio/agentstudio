import Testing

func badOffTestTaskExpectations() async throws {
    await valueFromDedicatedThread {
        #expect(observed)
        _ = try #require(optional)
        Issue.record("off-task failure")
    }
    try await withoutBlockingCooperativePool(blockingWork: {
        #expect(observed)
        _ = try #require(optional)
        Issue.record("off-task failure")
    })
}
