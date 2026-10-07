import AgentStudioIPCTransport
import Foundation
import Testing

@Suite("JSON-RPC encoded result framing")
struct JSONRPCEncodedResultTests {
    @Test(
        "cached result framing preserves identifiers and the complete result",
        arguments: [JSONRPCIdentifier.number(9), .string("quoted\"\nidentifier"), .null])
    func resultFramingPreservesSemantics(identifier: JSONRPCIdentifier) throws {
        let result = JSONValue.object([
            "text": .string("escaped\nline and unicode 🐒"),
            "values": .array([.null, .bool(true), .number(12.5)]),
        ])
        let encodedResult = try JSONEncoder().encode(result)
        let framed = try JSONRPCCodec.encodeResponseBytes(
            id: identifier, encodedResult: encodedResult, maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes)
        var reader = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes)
        let frames = try reader.append(framed)
        #expect(frames.count == 1)
        let frame = try #require(frames.first)
        let served = try JSONRPCCodec.decodeResponse(frame)
        let referenceBytes = try JSONRPCCodec.encodeResponse(.success(id: identifier, result: result))
        let reference = try JSONRPCCodec.decodeResponse(referenceBytes)
        #expect(served == reference)
    }

    @Test("encoded frames admit their exact bound and refuse smaller or nonpositive bounds")
    func frameBoundsReturnTypedErrors() throws {
        let result = Data("{}".utf8)
        let generous = try JSONRPCCodec.encodeResponseBytes(id: .number(1), encodedResult: result, maxFrameBytes: 1024)
        let byteCount = generous.count - 1
        let exact = try JSONRPCCodec.encodeResponseBytes(
            id: .number(1), encodedResult: result, maxFrameBytes: byteCount)
        #expect(exact == generous)
        for bound in [byteCount - 1, 0, -1] {
            let expected = NDJSONFrameError(reason: .frameTooLarge, frameByteCount: byteCount, maximumFrameBytes: bound)
            #expect(throws: expected) {
                try JSONRPCCodec.encodeResponseBytes(id: .number(1), encodedResult: result, maxFrameBytes: bound)
            }
        }
    }
}
