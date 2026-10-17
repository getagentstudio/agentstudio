import Foundation

/// A new monotonic wire counter above the JSON safe-integer range is an
/// internal invariant failure, never a rounded response.
package enum IPCPaneNumericEncodingError: Error, Equatable, Sendable {
    case aboveSafeIntegerBound
}

/// Only the new pane-context contracts use these guards. Existing wire types
/// keep their established Codable behavior.
package enum IPCPaneNumericCoding {
    package static func requireSafe(_ value: UInt64) throws {
        guard value <= UInt64(IPCSchemaScalars.maximumExactInteger) else {
            throw IPCPaneNumericEncodingError.aboveSafeIntegerBound
        }
    }

    package static func requireSafe(_ value: Int) throws {
        guard value >= -Int(IPCSchemaScalars.maximumExactInteger),
            value <= Int(IPCSchemaScalars.maximumExactInteger)
        else { throw IPCPaneNumericEncodingError.aboveSafeIntegerBound }
    }

    package static func decodeUnsigned<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>, forKey key: Key
    ) throws -> UInt64 {
        let value = try container.decode(UInt64.self, forKey: key)
        guard value <= UInt64(IPCSchemaScalars.maximumExactInteger) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Expected a non-negative JSON safe integer")
        }
        return value
    }

    package static func decodeSigned<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>, forKey key: Key
    ) throws -> Int {
        let value = try container.decode(Int.self, forKey: key)
        guard value >= -Int(IPCSchemaScalars.maximumExactInteger),
            value <= Int(IPCSchemaScalars.maximumExactInteger)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Expected a JSON safe integer")
        }
        return value
    }
}
