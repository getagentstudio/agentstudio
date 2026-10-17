import Foundation

/// Discovery keeps the original result bytes for the owning typed/schema decoder.
package struct JSONRPCDiscoveryResponse: Sendable {
    package let id: JSONRPCIdentifier?
    package let resultBytes: Data?
    package let error: JSONRPCErrorPayload?
}

extension JSONRPCCodec {
    package static func decodeDiscoveryResponse(_ payload: String) throws -> JSONRPCDiscoveryResponse {
        do {
            let bytes = Data(payload.utf8)
            // Foundation admits the entire JSON syntax and the ordinary envelope
            // before the slicer visits any byte. It does not build a result tree.
            let header = try JSONDecoder().decode(JSONRPCDiscoveryResponseHeader.self, from: bytes)
            let result: Data?
            if header.hasResult {
                result = try JSONRPCResultByteSlice(bytes: Array(bytes)).resultBytes()
            } else {
                result = nil
            }
            return JSONRPCDiscoveryResponse(id: header.id, resultBytes: result, error: header.error)
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw JSONRPCError(reason: .invalidResponse, message: "Response body is not a valid JSON-RPC response")
        }
    }

    static func validateResponse(version: String, hasResult: Bool, hasError: Bool) throws {
        guard version == "2.0" else {
            throw JSONRPCError(reason: .invalidJSONRPCVersion, message: "JSON-RPC response version must be 2.0")
        }
        guard hasResult != hasError else {
            throw JSONRPCError(
                reason: .invalidResponse, message: "JSON-RPC response must include exactly one of result or error")
        }
    }
}

private struct JSONRPCDiscoveryResponseHeader: Decodable {
    let id: JSONRPCIdentifier?
    let hasResult: Bool
    let error: JSONRPCErrorPayload?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let version = try fields.decode(String.self, forKey: .jsonrpc)
        id = try fields.decodeIfPresent(JSONRPCIdentifier.self, forKey: .id)
        if fields.contains(.result) { hasResult = try !fields.decodeNil(forKey: .result) } else { hasResult = false }
        error = try fields.decodeIfPresent(JSONRPCErrorPayload.self, forKey: .error)
        try JSONRPCCodec.validateResponse(version: version, hasResult: hasResult, hasError: error != nil)
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
}

/// Finds only the first top-level result span in already admitted JSON.
/// Keys are decoded natively (including Unicode escapes), matching Foundation's
/// first-key lookup. This is a byte locator, never an alternative JSON validator.
private struct JSONRPCResultByteSlice {
    let bytes: [UInt8]

    func resultBytes() throws -> Data {
        let start = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        var position = skippingWhitespace(from: start)
        guard position < bytes.count, bytes[position] == 0x7b else { throw invalidSpan() }
        position += 1
        while position < bytes.count {
            position = skippingWhitespace(from: position)
            guard position < bytes.count, bytes[position] == 0x22 else { throw invalidSpan() }
            let keyStart = position
            let keyEnd = try stringEnd(from: position)
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<keyEnd]))
            position = skippingWhitespace(from: keyEnd)
            guard position < bytes.count, bytes[position] == 0x3a else { throw invalidSpan() }
            let resultStart = position + 1
            let start = skippingWhitespace(from: resultStart)
            let end = try valueEnd(from: start)
            if key == "result" {
                return Data(bytes[resultStart..<skippingWhitespace(from: end)])
            }
            position = skippingWhitespace(from: end)
            guard position < bytes.count, bytes[position] == 0x2c else { throw invalidSpan() }
            position += 1
        }
        throw invalidSpan()
    }

    private func valueEnd(from start: Int) throws -> Int {
        guard start < bytes.count else { throw invalidSpan() }
        if bytes[start] == 0x22 { return try stringEnd(from: start) }
        if bytes[start] == 0x7b || bytes[start] == 0x5b {
            var depth = 0
            var position = start
            while position < bytes.count {
                switch bytes[position] {
                case 0x22:
                    position = try stringEnd(from: position)
                    continue
                case 0x7b, 0x5b: depth += 1
                case 0x7d, 0x5d:
                    depth -= 1
                    if depth == 0 { return position + 1 }
                default: break
                }
                position += 1
            }
            throw invalidSpan()
        }
        var end = start
        while end < bytes.count, !isWhitespace(bytes[end]), bytes[end] != 0x2c, bytes[end] != 0x7d { end += 1 }
        guard end > start else { throw invalidSpan() }
        return end
    }

    private func stringEnd(from start: Int) throws -> Int {
        var position = start + 1
        while position < bytes.count {
            if bytes[position] == 0x5c {
                position += 2
                continue
            }
            if bytes[position] == 0x22 { return position + 1 }
            position += 1
        }
        throw invalidSpan()
    }

    private func skippingWhitespace(from start: Int) -> Int {
        var position = start
        while position < bytes.count, isWhitespace(bytes[position]) { position += 1 }
        return position
    }

    private func isWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d }
    private func invalidSpan() -> JSONRPCError {
        JSONRPCError(reason: .invalidResponse, message: "Response body is not a valid JSON-RPC response")
    }
}
