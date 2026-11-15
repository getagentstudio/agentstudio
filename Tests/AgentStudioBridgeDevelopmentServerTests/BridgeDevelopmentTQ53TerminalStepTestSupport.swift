import AgentStudioTestHarness

/// The producer reports both reaching the seam and ending before reaching it.
/// Unlike HeldStep.fail, a failed arrival also terminates firstArrival.
final class TQ53TerminalStep<Arrival: Sendable>: Sendable {
    private let outcome: HeldStep<Result<Arrival, any Error>>

    init(_ name: String) {
        outcome = HeldStep(name)
    }

    var hasArrived: Bool { !outcome.recordedArrivals.isEmpty }
    var arrivalCount: Int { outcome.recordedArrivals.count }

    func arrive(_ arrival: Arrival) async throws {
        try await outcome.arrive(.success(arrival))
    }

    func firstArrival() async throws -> Arrival {
        try await outcome.firstArrival().get()
    }

    func release() { outcome.release() }

    func failBeforeArrival(_ error: any Error) async {
        outcome.release()
        try? await outcome.arrive(.failure(error))
    }

    func run<Output: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        describeCompletion: (Output) -> String,
        operation: () async throws -> Output
    ) async throws -> Output {
        do {
            let output = try await operation()
            guard hasArrived else {
                throw TQ53MissingArrival(stepName: outcome.name, observed: describeCompletion(output))
            }
            return output
        } catch {
            await failBeforeArrival(error)
            throw error
        }
    }
}

struct TQ53MissingArrival: Error, CustomStringConvertible {
    let stepName: String
    let observed: String

    var description: String {
        "\(stepName): producer completed without arrival; observed \(observed)"
    }
}
