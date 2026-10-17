import Foundation

extension JSONRPCCodec {
    /// Fixed runtime results already passed their owning typed contract before caching.
    package static func encodeResponseBytes(
        id: JSONRPCIdentifier, encodedResult: Data, maxFrameBytes: Int
    ) throws -> Data {
        var frame = Data("{\"jsonrpc\":\"2.0\",\"id\":".utf8)
        frame.append(try JSONEncoder().encode(id))
        frame.append(Data(",\"result\":".utf8))
        frame.append(encodedResult)
        frame.append(0x7d)
        guard frame.count <= maxFrameBytes else {
            throw NDJSONFrameError(
                reason: .frameTooLarge, frameByteCount: frame.count, maximumFrameBytes: maxFrameBytes)
        }
        frame.append(0x0a)
        return frame
    }
}
