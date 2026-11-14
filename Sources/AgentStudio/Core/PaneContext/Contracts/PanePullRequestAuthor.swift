import Foundation

package enum PanePullRequestAuthor: Hashable, Sendable, Codable {
    case paneAgent(sourcePaneId: PaneId, conversation: BridgeAgentContributorIdentity?)
    case client(credentialKey: String)
    case person
}

package enum PanePullRequestAuthorKeyCodec {
    package static func encode(_ author: PanePullRequestAuthor) -> String {
        switch author {
        case .person: "person"
        case .client(let credentialKey): "client:\(encodeComponent(credentialKey))"
        case .paneAgent(let pane, let conversation):
            if let conversation {
                "agent:\(pane.uuidString):\(conversation.provider.value):\(encodeComponent(conversation.sessionRef.value))"
            } else {
                "agent:\(pane.uuidString)"
            }
        }
    }

    package static func decode(_ key: String) throws -> PanePullRequestAuthor {
        let author: PanePullRequestAuthor
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "person" where parts.count == 1: author = .person
        case "client" where parts.count == 2:
            guard let credentialKey = parts[1].removingPercentEncoding, !credentialKey.isEmpty else {
                throw BridgeLinkIdentityError.invalidEncoding
            }
            author = .client(credentialKey: credentialKey)
        case "agent" where parts.count == 2 || parts.count == 4:
            guard let pane = UUID(uuidString: parts[1]) else { throw BridgeLinkIdentityError.invalidEncoding }
            let conversation: BridgeAgentContributorIdentity?
            if parts.count == 4 {
                guard let reference = parts[3].removingPercentEncoding else {
                    throw BridgeLinkIdentityError.invalidEncoding
                }
                conversation = BridgeAgentContributorIdentity(
                    provider: try BridgeAgentProviderName(parts[2]), sessionRef: try BridgeAgentSessionRef(reference))
            } else {
                conversation = nil
            }
            author = .paneAgent(sourcePaneId: PaneId(existingUUID: pane), conversation: conversation)
        default: throw BridgeLinkIdentityError.invalidEncoding
        }
        guard encode(author) == key else { throw BridgeLinkIdentityError.invalidEncoding }
        return author
    }

    private static func encodeComponent(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 45 || byte == 46 || byte == 95 || byte == 126
            {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}
