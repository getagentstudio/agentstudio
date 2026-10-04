import Foundation

/// The identity and handled prefixes reported by the app's local cursors.
package struct IPCCLIStoreReadThrough: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let storeId: UUID
    package let outbox: Int64
    package let lifecycleReport: Int64?

    package init(storeId: UUID, outbox: Int64, lifecycleReport: Int64? = nil) {
        self.storeId = storeId
        self.outbox = outbox
        self.lifecycleReport = lifecycleReport
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let receivedKeys = try decoder.container(keyedBy: ReadThroughCodingKey.self).allKeys
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard receivedKeys.allSatisfy({ allowedKeys.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "CLI store read-through carries undeclared fields"))
        }
        storeId = try container.decode(UUID.self, forKey: .storeId)
        outbox = try container.decode(Int64.self, forKey: .outbox)
        lifecycleReport =
            container.contains(.lifecycleReport)
            ? try container.decode(Int64.self, forKey: .lifecycleReport) : nil
        guard Self.isExactCounter(outbox), lifecycleReport.map(Self.isExactCounter) ?? true else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "CLI store read-through requires exact nonnegative JSON integers"))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        guard Self.isExactCounter(outbox), lifecycleReport.map(Self.isExactCounter) ?? true else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "CLI store read-through requires exact nonnegative JSON integers"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storeId, forKey: .storeId)
        try container.encode(outbox, forKey: .outbox)
        try container.encodeIfPresent(lifecycleReport, forKey: .lifecycleReport)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "storeId", description: "Identity of the CLI file whose cursors were read",
                schema: IPCSchemaScalars.uuid),
            .init(
                name: "outbox", description: "Highest outbox row handled by the app",
                schema: IPCSchemaScalars.unsignedInteger),
            .init(
                name: "lifecycleReport", description: "Highest lifecycle report handled by the app",
                schema: IPCSchemaScalars.unsignedInteger, presence: .optional),
        ])
    }

    private static func isExactCounter(_ value: Int64) -> Bool {
        (0...IPCSchemaScalars.maximumExactInteger).contains(value)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case storeId, outbox, lifecycleReport
    }
}

private struct ReadThroughCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
