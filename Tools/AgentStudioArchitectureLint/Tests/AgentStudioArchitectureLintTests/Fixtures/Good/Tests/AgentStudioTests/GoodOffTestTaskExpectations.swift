import Testing

func goodOffTestTaskExpectations() async throws {
    let observed = await valueFromDedicatedThread { true }
    #expect(observed)
    let optional = await withoutBlockingCooperativePool { Optional(true) }
    _ = try #require(optional)
    let failure = await withoutBlockingCooperativePool { "observation" }
    Issue.record(failure)
}
