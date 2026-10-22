import Foundation

package enum AgentStudioOTLPTraceProjection {
    package static func project(_ record: AgentStudioTraceRecord) -> AgentStudioOTLPProjectedLogRecord {
        let safeResource = safeResource(record.resource)
        let resource = projectedResource(safeResource)
        var attributes = projectedAttributes(record.attributes, resource: safeResource)
        if record.timeUnixNano <= UInt64(Int.max) {
            attributes["agentstudio.event.time_unix_nano"] = .int(Int(record.timeUnixNano))
        }
        return AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: record.timeUnixNano,
            severityText: record.severityText,
            body: safeBody(record.body),
            traceID: validTraceID(record.traceID),
            spanID: validSpanID(record.spanID),
            parentSpanID: validSpanID(record.parentSpanID),
            resource: resource,
            scope: record.scope,
            attributes: attributes
        )
    }

    private static let allowedResourceKeys: Set<String> = [
        "agentstudio.build.config",
        "agentstudio.release_channel",
        "agentstudio.runtime_flavor",
        "agent.proof.launch",
        "agent.proof.marker",
        "dev.build.config",
        "dev.branch.name",
        "dev.release.channel",
        "dev.repo.hash",
        "dev.runtime.flavor",
        "dev.worktree.hash",
        "service.name",
        "service.version",
    ]

    private static let resourceKeysProjectedAsLogAttributes: Set<String> = [
        "agentstudio.release_channel",
        "agentstudio.runtime_flavor",
        "agent.proof.launch",
        "agent.proof.marker",
        "dev.release.channel",
        "dev.repo.hash",
        "dev.runtime.flavor",
        "dev.worktree.hash",
        "dev.branch.name",
        "service.version",
    ]

    private static func projectedAttributes(
        _ attributes: [String: AgentStudioTraceValue], resource: [String: String]
    ) -> [String: AgentStudioTraceValue] {
        var projected = attributes
        for (key, value) in resource where resourceKeysProjectedAsLogAttributes.contains(key) {
            projected[key] = .string(value)
        }
        return projected
    }

    private static func projectedResource(_ safeResource: [String: String]) -> [String: String] {
        safeResource.filter { key, _ in
            allowedResourceKeys.contains(key)
        }
    }

    private static func safeResource(_ resource: [String: String]) -> [String: String] {
        var projected: [String: String] = [:]
        for (key, value) in resource where allowedResourceKeys.contains(key) && isSafeResourceValue(value) {
            projected[key] = value
        }
        return projected
    }

    private static func safeBody(_ body: String) -> String {
        isSafeEventName(body) ? body : "agentstudio.trace.record"
    }

    private static func isSafeEventName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
                || scalar == ":"
        }
    }

    private static func isSafeResourceValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160 else {
            return false
        }
        let normalizedValue = value.lowercased()
        return !normalizedValue.hasPrefix("/")
            && !normalizedValue.contains("/users/")
            && !normalizedValue.contains("://")
            && !normalizedValue.contains("\\")
            && !normalizedValue.contains("\n")
            && !normalizedValue.contains("\r")
    }

    private static func validTraceID(_ value: String?) -> String? {
        validHexIdentifier(value, requiredLength: 32)
    }

    private static func validSpanID(_ value: String?) -> String? {
        validHexIdentifier(value, requiredLength: 16)
    }

    private static func validHexIdentifier(_ value: String?, requiredLength: Int) -> String? {
        guard let value, value.count == requiredLength else {
            return nil
        }
        guard value.utf8.contains(where: { $0 != 48 }) else {
            return nil
        }
        guard
            value.utf8.allSatisfy({ byte in
                byte >= 48 && byte <= 57 || byte >= 97 && byte <= 102
            })
        else {
            return nil
        }
        return value
    }
}
