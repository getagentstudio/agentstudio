import AgentStudioProgrammaticControl
import Foundation

/// One IPC read's exact wire accounting. Payloads are measured once and reused
/// when the unchanged page search tries a smaller domain budget.
struct PaneContextIPCReplySizing {
    private struct MeasuredMessage {
        let value: IPCPaneMessageDetail
        let byteCount: Int
    }

    private let encoder = JSONEncoder()
    private var messages: [UUID: [UUID: MeasuredMessage]] = [:]

    mutating func encodedSize(_ result: IPCPaneContextGetResult) throws -> Int {
        let framing = IPCPaneContextGetResult(
            paneId: result.paneId, revision: result.revision, agentTitle: result.agentTitle,
            agentLine: result.agentLine, session: result.session, messages: [], drawerMessages: [],
            links: result.links, pullRequests: result.pullRequests, truncation: result.truncation)
        var byteCount = try encoder.encode(framing).count
        byteCount += try messageArrayPayloadSize(result.messages)
        byteCount += max(0, result.drawerMessages.count - 1)
        for group in result.drawerMessages {
            byteCount += try encoder.encode(IPCPaneDrawerMessageGroup(sourcePaneId: group.sourcePaneId, messages: []))
                .count
            byteCount += try messageArrayPayloadSize(group.messages)
        }
        return byteCount
    }

    private mutating func messageArrayPayloadSize(_ values: [IPCPaneMessageDetail]) throws -> Int {
        var byteCount = max(0, values.count - 1)
        for value in values {
            if let previous = messages[value.sourcePaneId]?[value.id], previous.value == value {
                byteCount += previous.byteCount
            } else {
                let measured = try encoder.encode(value).count
                messages[value.sourcePaneId, default: [:]][value.id] = MeasuredMessage(
                    value: value, byteCount: measured)
                byteCount += measured
            }
        }
        return byteCount
    }
}
