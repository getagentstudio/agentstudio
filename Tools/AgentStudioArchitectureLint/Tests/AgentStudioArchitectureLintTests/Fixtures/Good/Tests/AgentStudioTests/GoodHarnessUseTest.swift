import AgentStudioTestHarness

struct GoodCountingGate {
    var count = 0
}

struct GoodEventRecorder {
    let heldStep: HeldStep<Void>
}

func waitUntilDrained() async -> Int { 1 }

func requireFocusCommitted() async throws -> String { "" }

func waitsForNothing() async {}

func requiredValue() async {}
