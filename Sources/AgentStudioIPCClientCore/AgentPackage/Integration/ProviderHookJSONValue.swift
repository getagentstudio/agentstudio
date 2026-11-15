import AgentStudioIPCTransport
import Foundation

/// Provider-owned JSON retains object order and numeric spelling through edits.
/// Foundation validates syntax; this reader only retains the validated tokens.
package indirect enum ProviderHookJSONValue: Equatable, Sendable {
    package struct Member: Equatable, Sendable {
        package let name: String
        package var value: ProviderHookJSONValue
    }

    case object([Member])
    case array([Self])
    case scalar(String)

    package static func parse(_ data: Data) throws -> Self {
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var reader = TokenReader(bytes: Array(data))
        return try reader.value()
    }

    package static func string(_ value: String) -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("\"\"".utf8)
        return .scalar(String(bytes: data, encoding: .utf8) ?? "\"\"")
    }

    package static func number(_ value: Double) -> Self {
        if let integer = Int64(exactly: value) { return .scalar(String(integer)) }
        return .scalar(String(value))
    }

    package static func boolean(_ value: Bool) -> Self { .scalar(value ? "true" : "false") }

    package var stringValue: String? {
        guard case .scalar(let text) = self else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(text.utf8))
    }

    package var numberValue: Double? {
        guard case .scalar(let text) = self, text.first != "\"" else { return nil }
        return Double(text)
    }

    package var booleanValue: Bool? {
        switch self {
        case .scalar("true"): true
        case .scalar("false"): false
        default: nil
        }
    }

    package var members: [Member]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    package var elements: [Self]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    package subscript(_ name: String) -> Self? { members?.last(where: { $0.name == name })?.value }

    package var serialized: String {
        switch self {
        case .scalar(let text): text
        case .array(let values): "[" + values.map(\.serialized).joined(separator: ",") + "]"
        case .object(let members):
            "{" + members.map { Self.string($0.name).serialized + ":" + $0.value.serialized }.joined(separator: ",")
                + "}"
        }
    }

    package func semanticallyEquals(_ other: Self) -> Bool {
        guard let left = try? JSONDecoder().decode(JSONValue.self, from: Data(serialized.utf8)),
            let right = try? JSONDecoder().decode(JSONValue.self, from: Data(other.serialized.utf8))
        else { return false }
        return left == right
    }

    package mutating func set(_ name: String, to value: Self?) {
        guard case .object(var fields) = self else { return }
        if let index = fields.firstIndex(where: { $0.name == name }) {
            if let value { fields[index].value = value } else { fields.remove(at: index) }
        } else if let value {
            fields.append(.init(name: name, value: value))
        }
        self = .object(fields)
    }
}

private struct TokenReader {
    let bytes: [UInt8]
    var position = 0

    mutating func value() throws -> ProviderHookJSONValue {
        whitespace()
        guard position < bytes.count else { throw CocoaError(.propertyListReadCorrupt) }
        switch bytes[position] {
        case 123: return try object()
        case 91: return try array()
        case 34: return .scalar(try stringToken())
        default:
            let start = position
            while position < bytes.count, ![UInt8(44), 93, 125, 32, 10, 13, 9].contains(bytes[position]) {
                position += 1
            }
            guard let text = String(bytes: bytes[start..<position], encoding: .utf8) else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return .scalar(text)
        }
    }

    mutating func object() throws -> ProviderHookJSONValue {
        position += 1
        whitespace()
        var fields: [ProviderHookJSONValue.Member] = []
        while position < bytes.count, bytes[position] != 125 {
            let token = try stringToken()
            let name = try JSONDecoder().decode(String.self, from: Data(token.utf8))
            guard !fields.contains(where: { $0.name == name }) else { throw CocoaError(.propertyListReadCorrupt) }
            whitespace()
            position += 1
            fields.append(.init(name: name, value: try value()))
            whitespace()
            if position < bytes.count, bytes[position] == 44 {
                position += 1
                whitespace()
            }
        }
        position += 1
        return .object(fields)
    }

    mutating func array() throws -> ProviderHookJSONValue {
        position += 1
        whitespace()
        var elements: [ProviderHookJSONValue] = []
        while position < bytes.count, bytes[position] != 93 {
            elements.append(try value())
            whitespace()
            if position < bytes.count, bytes[position] == 44 {
                position += 1
                whitespace()
            }
        }
        position += 1
        return .array(elements)
    }

    mutating func stringToken() throws -> String {
        let start = position
        position += 1
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == 92 {
                position += 1
            } else if byte == 34 {
                guard let text = String(bytes: bytes[start..<position], encoding: .utf8) else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
                return text
            }
        }
        throw CocoaError(.propertyListReadCorrupt)
    }

    mutating func whitespace() {
        while position < bytes.count, [UInt8(32), 10, 13, 9].contains(bytes[position]) { position += 1 }
    }
}
