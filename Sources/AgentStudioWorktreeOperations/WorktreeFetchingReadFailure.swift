import Foundation

package struct WorktreeFetchingReadFailure: Codable, Sendable, Equatable {
    package let fetch: WorktreeFetchStatus

    package init(fetch: WorktreeFetchStatus) {
        self.fetch = fetch
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case failure
        case leftovers
        case fetch
    }

    private struct Failure: Codable, Equatable {
        let kind: String
    }

    private struct Leftovers: Codable, Equatable {
        let status: String
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        let failure = try container.decode(Failure.self, forKey: .failure)
        let leftovers = try container.decode(Leftovers.self, forKey: .leftovers)
        guard outcome == "failed", failure.kind == "readFailed", leftovers.status == "notNeeded" else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Invalid fetching read failure outcome."
            )
        }
        fetch = try container.decode(WorktreeFetchStatus.self, forKey: .fetch)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("failed", forKey: .outcome)
        try container.encode(Failure(kind: "readFailed"), forKey: .failure)
        try container.encode(Leftovers(status: "notNeeded"), forKey: .leftovers)
        try container.encode(fetch, forKey: .fetch)
    }
}
