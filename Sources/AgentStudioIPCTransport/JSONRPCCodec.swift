import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([Self].self) {
            self = .array(arrayValue)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public enum JSONRPCIdentifier: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            self = .number(try container.decode(Int.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct JSONRPCRequest: Equatable, Sendable {
    public let id: JSONRPCIdentifier?
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCIdentifier?, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCClientRequest: Encodable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCIdentifier
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCIdentifier, method: String, params: JSONValue?) throws {
        guard !method.isEmpty else {
            throw JSONRPCError(reason: .invalidMethod, message: "JSON-RPC request method must be non-empty")
        }

        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCError: Error, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case invalidJSON
        case invalidRequest
        case invalidJSONRPCVersion
        case invalidMethod
        case invalidParams
        case unsupportedBatch
        case invalidResponse
        case invalidApplicationErrorCode
        case responseEncodingFailed
    }

    public let reason: Reason
    public let message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }
}

public struct JSONRPCErrorPayload: Codable, Equatable, Sendable {
    public static let applicationErrorCodeRange = (-32_099)...(-32_000)

    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func application(code: Int, message: String, data: JSONValue? = nil) throws -> Self {
        guard Self.applicationErrorCodeRange.contains(code) else {
            throw JSONRPCError(
                reason: .invalidApplicationErrorCode,
                message: "Application error code must be in the JSON-RPC server error range"
            )
        }

        return Self(code: code, message: message, data: data)
    }
}

public struct JSONRPCResponse: Encodable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCIdentifier?
    public let result: JSONValue?
    public let error: JSONRPCErrorPayload?

    public init(id: JSONRPCIdentifier?, result: JSONValue?, error: JSONRPCErrorPayload?) throws {
        guard (result == nil) != (error == nil) else {
            throw JSONRPCError(
                reason: .invalidResponse,
                message: "JSON-RPC response must include exactly one of result or error"
            )
        }

        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: JSONRPCIdentifier?, result: JSONValue) -> Self {
        Self(validatedID: id, result: result, error: nil)
    }

    public static func failure(id: JSONRPCIdentifier?, error: JSONRPCErrorPayload) -> Self {
        Self(validatedID: id, result: nil, error: error)
    }

    private init(validatedID id: JSONRPCIdentifier?, result: JSONValue?, error: JSONRPCErrorPayload?) {
        jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct JSONRPCResponseMessage: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCIdentifier?
    public let result: JSONValue?
    public let error: JSONRPCErrorPayload?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONRPCIdentifier.self, forKey: .id)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(JSONRPCErrorPayload.self, forKey: .error)

        try JSONRPCCodec.validateResponse(version: jsonrpc, hasResult: result != nil, hasError: error != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }
}

public struct JSONRPCNotification: Encodable, Equatable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) throws {
        guard !method.isEmpty else {
            throw JSONRPCError(reason: .invalidMethod, message: "JSON-RPC notification method must be non-empty")
        }

        jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public enum JSONRPCCodec {
    public static func encodeRequest(_ request: JSONRPCClientRequest) throws -> String {
        let encoder = JSONEncoder()

        do {
            let data = try encoder.encode(request)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw JSONRPCError(
                    reason: .responseEncodingFailed,
                    message: "JSON-RPC request was not valid UTF-8"
                )
            }
            return encoded
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw JSONRPCError(
                reason: .responseEncodingFailed,
                message: "JSON-RPC request could not be encoded"
            )
        }
    }

    public static func decodeRequest(_ payload: String) throws -> JSONRPCRequest {
        try decodeRequestPayload(payload, maxBytes: nil)
    }

    public static func decodeRequest(_ payload: String, maxBytes: Int) throws -> JSONRPCRequest {
        try decodeRequestPayload(payload, maxBytes: maxBytes)
    }

    private static func decodeRequestPayload(_ payload: String, maxBytes: Int?) throws -> JSONRPCRequest {
        if let maxBytes, payload.utf8.count > maxBytes {
            throw JSONRPCError(reason: .invalidRequest, message: "JSON-RPC request exceeds the byte limit")
        }

        let data = Data(payload.utf8)
        let jsonValue: JSONValue

        do {
            jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JSONRPCError(reason: .invalidJSON, message: "Request body is not valid JSON")
        }

        guard case .object(let object) = jsonValue else {
            if case .array = jsonValue {
                throw JSONRPCError(reason: .unsupportedBatch, message: "Batch requests are not supported")
            }

            throw JSONRPCError(reason: .invalidRequest, message: "JSON-RPC request must be an object")
        }

        guard object["jsonrpc"] == .string("2.0") else {
            throw JSONRPCError(reason: .invalidJSONRPCVersion, message: "JSON-RPC version must be 2.0")
        }

        guard case .string(let method)? = object["method"], !method.isEmpty else {
            throw JSONRPCError(reason: .invalidMethod, message: "JSON-RPC method must be a non-empty string")
        }

        if let params = object["params"], !isObjectOrNull(params) {
            throw JSONRPCError(reason: .invalidParams, message: "JSON-RPC params must be an object when present")
        }

        return JSONRPCRequest(
            id: try decodeIdentifier(from: object["id"]),
            method: method,
            params: object["params"]
        )
    }

    public static func encodeResponse(_ response: JSONRPCResponse) throws -> String {
        let encoder = JSONEncoder()

        do {
            let data = try encoder.encode(response)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw JSONRPCError(
                    reason: .responseEncodingFailed,
                    message: "JSON-RPC response was not valid UTF-8"
                )
            }
            return encoded
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw JSONRPCError(
                reason: .responseEncodingFailed,
                message: "JSON-RPC response could not be encoded"
            )
        }
    }

    public static func decodeResponse(_ payload: String) throws -> JSONRPCResponseMessage {
        do {
            return try JSONDecoder().decode(JSONRPCResponseMessage.self, from: Data(payload.utf8))
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw JSONRPCError(reason: .invalidResponse, message: "Response body is not a valid JSON-RPC response")
        }
    }

    public static func encodeNotification(_ notification: JSONRPCNotification) throws -> String {
        let encoder = JSONEncoder()

        do {
            let data = try encoder.encode(notification)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw JSONRPCError(
                    reason: .responseEncodingFailed,
                    message: "JSON-RPC notification was not valid UTF-8"
                )
            }
            return encoded
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw JSONRPCError(
                reason: .responseEncodingFailed,
                message: "JSON-RPC notification could not be encoded"
            )
        }
    }

    public static func encodeJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func decodeIdentifier(from value: JSONValue?) throws -> JSONRPCIdentifier? {
        guard let value else {
            return nil
        }

        switch value {
        case .string(let id):
            return .string(id)
        case .number(let id):
            guard id.isFinite, id.rounded() == id else {
                throw JSONRPCError(reason: .invalidRequest, message: "JSON-RPC numeric id must be an integer")
            }
            guard let integerID = Int(exactly: id) else {
                throw JSONRPCError(reason: .invalidRequest, message: "JSON-RPC numeric id is out of range")
            }
            return .number(integerID)
        case .null:
            return .null
        default:
            throw JSONRPCError(reason: .invalidRequest, message: "JSON-RPC id must be a string, integer, or null")
        }
    }

    private static func isObjectOrNull(_ value: JSONValue) -> Bool {
        switch value {
        case .object, .null:
            true
        default:
            false
        }
    }
}
