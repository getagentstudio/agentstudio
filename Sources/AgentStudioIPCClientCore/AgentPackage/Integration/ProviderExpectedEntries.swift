import Foundation

package enum ProviderExpectedEntries {
    package static func eventNames(provider: AgentPackageProvider) -> [String] {
        switch provider {
        case .claude: ClaudeCodeHookEvent.allCases.map(\.rawValue)
        case .codex: CodexHookEventName.installedEvents.map(\.rawValue)
        case .cursor: CursorHookEventName.installedEvents.map(\.rawValue)
        }
    }

    package static func entries(layout: ProviderIntegrationLayout) -> [(event: String, group: ProviderHookGroup)] {
        eventNames(provider: layout.provider).map { event in
            let timeout: Double?
            let isAsync: Bool?
            let typeField: ProviderCommandHook.TypeFieldPresence
            switch layout.provider {
            case .claude: (timeout, isAsync, typeField) = (10, true, .command)
            case .codex:
                (timeout, isAsync, typeField) = (
                    event == "SessionEnd" || event == "Interrupt" ? 1 : 5, event == "SessionEnd" ? nil : true, .command
                )
            case .cursor: (timeout, isAsync, typeField) = (nil, nil, .absent)
            }
            let command = "\"\(shellQuotedPath(layout.scriptURL.path))\" \(event)"
            return (
                event,
                ProviderHookGroup(
                    matcher: nil,
                    handlers: [
                        .command(
                            .init(
                                command: command, timeoutSeconds: timeout, isAsync: isAsync, typeField: typeField,
                                preserved: .object([])))
                    ], preserved: .object([]))
            )
        }
    }

    package static func snippet(layout: ProviderIntegrationLayout) throws -> String {
        var document = try ProviderHookFileDocument(provider: layout.provider, data: nil, path: layout.hookFileURL.path)
        for entry in entries(layout: layout) { document.setGroups([entry.group], event: entry.event) }
        return document.json.serialized + "\n"
    }

    package static func shellQuotedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
