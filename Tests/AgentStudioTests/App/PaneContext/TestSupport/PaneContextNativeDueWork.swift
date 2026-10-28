import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

/// Join source-owned progress after the one driven clock advance, including a cancelled wake's replacement.
func awaitDueNativeExecution(
    on owner: isolated PaneContextPopoverRefreshOwner<TestPushClock>,
    key: PaneContextPopoverConsumerKey, opening: UInt64, after previous: UUID, retiredWake: UInt64
) async throws -> PaneContextPopoverExecution {
    // The caller has driven time once. Producer joins cannot extend this fixed logical horizon.
    let drivenTime = owner.clock.now
    var joinedInputs: Set<UUID> = []
    var joinedWakes: Set<UInt64> = [retiredWake]
    while true {
        let current = owner.consumers[key]
        let consumer = try #require(current, "The native refresh consumer retired")
        try #require(consumer.opening == opening, "The native refresh opening was replaced")
        if let latest = consumer.latestExecution, latest.id != previous { return latest }
        if let operation = consumer.inputOperation {
            let distinct = joinedInputs.insert(operation).inserted
            try #require(distinct, "The input producer ended without admitting or retiring its successor")
            await owner.awaitInputCompletion(operation, key: key, opening: opening)
            continue
        }
        let scheduled = owner.scheduledWake()
        let replacement = try #require(
            scheduled,
            "The retired wake ended without a read, current input or replacement deadline")
        try #require(
            replacement.deadline <= drivenTime,
            "The replacement deadline must already be due; this helper never waits for future time")
        let distinct = joinedWakes.insert(replacement.sequence).inserted
        try #require(distinct, "A deadline producer ended without progress")
        await replacement.task.value
    }
}

/// Before driving time, join an in-flight canonical/read producer rather than assuming its old wake survives.
func awaitNativeRegistrationSuccessor(
    on owner: isolated PaneContextPopoverRefreshOwner<TestPushClock>,
    key: PaneContextPopoverConsumerKey, opening: UInt64
) async throws -> PaneContextPopoverWakeProducer {
    var joinedInputs = Set<UUID>()
    var joinedExecutions = Set<UUID>()
    while true {
        let consumer = try #require(owner.consumers[key], "The native registration consumer retired")
        try #require(consumer.opening == opening, "The native registration opening was replaced")
        if let operation = consumer.inputOperation {
            try #require(
                joinedInputs.insert(operation).inserted, "An input producer ended without registration progress")
            await owner.awaitInputCompletion(operation, key: key, opening: opening)
            continue
        }
        if let execution = consumer.execution {
            try #require(
                joinedExecutions.insert(execution.id).inserted, "A read producer ended without registration progress")
            await execution.task.value
            continue
        }
        let successor = owner.scheduledWakeProducer()
        return try #require(
            successor,
            "A cancelled wake left no useful successor, active input or read producer")
    }
}
