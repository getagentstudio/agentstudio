import AgentStudioIPCTransport
import Foundation

/// The new detail method budgets its result against the actual response id.
/// Every existing method keeps its established path and encoded bytes.
package enum AppIPCPaneContextReplyBudget {
    package static func envelopeOverheadBytes(id: JSONRPCIdentifier) throws -> Int {
        let placeholder = JSONValue.object([:])
        let encoded = try JSONRPCCodec.encodeResponse(JSONRPCResponse.success(id: id, result: placeholder))
        let framed = try NDJSONFrameEncoder.encode(encoded, maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes)
        return framed.count - (try JSONEncoder().encode(placeholder)).count
    }
}
