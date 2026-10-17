import AgentStudioIPCTransport
import Foundation
import Testing

@Suite("JSON-RPC discovery result bytes")
struct JSONRPCDiscoveryResultTests {
    @Test(
        "original result bytes preserve native response semantics",
        arguments: [
            #"{"jsonrpc":"2.0","id":1,"result":{"text":"braces } ], quote \" and slash \\","nested":[{},[],true,null,12.5]}}"#,
            #"{"result":[1,{"result":"nested"}],"extra":{"result":false},"jsonrpc":"2.0","id":"reply"}"#,
            #"{"extra":[{"nested":[1,2]}],"jsonrpc":"2.0","res\u0075lt":{"ok":true},"id":2}"#,
            #"{"jsonrpc":"2.0","id":3,"result":{"first":1},"result":{"later":2}}"#,
            #"{"jsonrpc":"2.0","id":4,"res\u0075lt":{"first":1},"result":{"later":2}}"#,
            #"{"jsonrpc":"2.0","id":null,"result":true}"#,
            #"{"jsonrpc":"2.0","result":"scalar with escaped \n"}"#,
            #"{"jsonrpc":"2.0","id":5,"result":-12.5e2}"#,
            #"{"jsonrpc":"2.0","id":6,"error":{"code":-32000,"message":"refused","data":{"reason":"denied"}}}"#,
            "\u{feff}{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}",
        ])
    func originalBytesPreserveSemantics(payload: String) throws {
        let reference = try JSONRPCCodec.decodeResponse(payload)
        let received = try JSONRPCCodec.decodeDiscoveryResponse(payload)
        let result: JSONValue?
        if let bytes = received.resultBytes {
            result = try JSONDecoder().decode(JSONValue.self, from: bytes)
        } else {
            result = nil
        }
        #expect(received.id == reference.id)
        #expect(received.error == reference.error)
        #expect(result == reference.result)
    }

    @Test(
        "discovery retains ordinary envelope errors",
        arguments: [
            "{", "[]", "null",
            #"{"jsonrpc":"1.0","id":1,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":1}"#,
            #"{"jsonrpc":"2.0","id":1,"result":null}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-32000,"message":"refused"}}"#,
            #"{"jsonrpc":"2.0","id":1.5,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":true,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{},"extra":[}"#,
        ])
    func ordinaryErrorsArePreserved(payload: String) throws {
        let referenceFailure = try responseDecodingFailure { _ = try JSONRPCCodec.decodeResponse(payload) }
        let discoveryFailure = try responseDecodingFailure { _ = try JSONRPCCodec.decodeDiscoveryResponse(payload) }
        let reference = try #require(referenceFailure)
        let received = try #require(discoveryFailure)
        #expect(received == reference)
    }
}

private func responseDecodingFailure(_ decode: () throws -> Void) throws -> JSONRPCError? {
    do {
        try decode()
        return nil
    } catch let error as JSONRPCError { return error }
}
