import Foundation

package struct ProviderCommandHook: Equatable, Sendable {
    package enum TypeFieldPresence: Equatable, Sendable { case absent, command }
    package let command: String
    package let timeoutSeconds: Double?
    package let isAsync: Bool?
    package let typeField: TypeFieldPresence
    package let preserved: ProviderHookJSONValue

    package var json: ProviderHookJSONValue {
        var value = preserved
        if typeField == .command { value.set("type", to: .string("command")) }
        value.set("command", to: .string(command))
        if let timeoutSeconds, value["timeout"]?.numberValue != timeoutSeconds {
            value.set("timeout", to: .number(timeoutSeconds))
        }
        if let isAsync { value.set("async", to: .boolean(isAsync)) }
        return value
    }
}

package enum ProviderHookHandler: Equatable, Sendable {
    case command(ProviderCommandHook)
    case other(ProviderHookJSONValue)

    package var json: ProviderHookJSONValue {
        switch self {
        case .command(let hook): hook.json
        case .other(let value): value
        }
    }

    static func decode(_ value: ProviderHookJSONValue, provider: AgentPackageProvider, path: String) throws -> Self {
        let commandShape = provider == .cursor ? value["type"] == nil : value["type"]?.stringValue == "command"
        guard commandShape, let command = value["command"]?.stringValue else { return .other(value) }
        let timeout = provider == .cursor ? nil : value["timeout"]?.numberValue
        let isAsync = provider == .cursor ? nil : value["async"]?.booleanValue
        if provider != .cursor {
            guard value["timeout"] == nil || value["timeout"] == .scalar("null") || timeout != nil,
                value["async"] == nil || isAsync != nil
            else { throw AgentPackageInstallationError.configurationUnreadable(path) }
        }
        return .command(
            .init(
                command: command, timeoutSeconds: timeout, isAsync: isAsync,
                typeField: provider == .cursor ? .absent : .command, preserved: value))
    }
}

package struct ProviderHookGroup: Equatable, Sendable {
    package let matcher: String?
    package var handlers: [ProviderHookHandler]
    package let preserved: ProviderHookJSONValue

    package var json: ProviderHookJSONValue {
        var value = preserved
        if let matcher { value.set("matcher", to: .string(matcher)) }
        if !handlers.isEmpty || preserved["hooks"] != nil {
            value.set("hooks", to: .array(handlers.map(\.json)))
        }
        return value
    }
}

package struct ProviderHookFileDocument: Equatable, Sendable {
    package let provider: AgentPackageProvider
    package private(set) var eventOrder: [String]
    package var groupsByEvent: [String: [ProviderHookGroup]]
    private var root: ProviderHookJSONValue

    package init(provider: AgentPackageProvider, data: Data?, path: String) throws {
        self.provider = provider
        do {
            root =
                try data.map(ProviderHookJSONValue.parse)
                ?? .object(provider == .cursor ? [.init(name: "version", value: .scalar("1"))] : [])
            guard root.members != nil else { throw CocoaError(.propertyListReadCorrupt) }
            let hooks = root["hooks"] ?? .object([])
            guard let events = hooks.members else { throw CocoaError(.propertyListReadCorrupt) }
            eventOrder = events.map(\.name)
            groupsByEvent = [:]
            for event in events {
                guard let entries = event.value.elements else { throw CocoaError(.propertyListReadCorrupt) }
                groupsByEvent[event.name] = try entries.map { entry in
                    if provider == .cursor {
                        return ProviderHookGroup(
                            matcher: nil,
                            handlers: [try ProviderHookHandler.decode(entry, provider: provider, path: path)],
                            preserved: .object([]))
                    }
                    guard entry.members != nil, entry["hooks"] == nil || entry["hooks"]?.elements != nil,
                        entry["matcher"] == nil || entry["matcher"] == .scalar("null")
                            || entry["matcher"]?.stringValue != nil
                    else { throw CocoaError(.propertyListReadCorrupt) }
                    return ProviderHookGroup(
                        matcher: entry["matcher"]?.stringValue,
                        handlers: try (entry["hooks"]?.elements ?? []).map {
                            try ProviderHookHandler.decode($0, provider: provider, path: path)
                        }, preserved: entry)
                }
            }
        } catch {
            throw AgentPackageInstallationError.configurationUnreadable(path)
        }
    }

    package mutating func setGroups(_ groups: [ProviderHookGroup], event: String) {
        if groupsByEvent[event] == nil { eventOrder.append(event) }
        groupsByEvent[event] = groups
    }

    package var json: ProviderHookJSONValue {
        var result = root
        let events = eventOrder.compactMap { event -> ProviderHookJSONValue.Member? in
            guard let groups = groupsByEvent[event] else { return nil }
            let values = provider == .cursor ? groups.flatMap { $0.handlers.map(\.json) } : groups.map(\.json)
            return .init(name: event, value: .array(values))
        }
        if !events.isEmpty || root["hooks"] != nil { result.set("hooks", to: .object(events)) }
        return result
    }

    package func encoded() -> Data { Data((json.serialized + "\n").utf8) }
}
