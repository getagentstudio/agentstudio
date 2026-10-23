import AgentStudioIPCTransport
import Foundation

package enum ProviderIntegrationVerdict: String, CaseIterable, Sendable {
    case current, unavailable, notInstalled, outdated, entriesMissing, notTrusted, trustUnknown

    var precedence: Int {
        switch self {
        case .unavailable: 0
        case .notInstalled: 1
        case .outdated: 2
        case .entriesMissing: 3
        case .notTrusted: 4
        case .trustUnknown: 5
        case .current: 6
        }
    }
}

package enum ProviderHookEntryAspect: String, Equatable, Sendable {
    case command, matcher, timeout
    case asynchronous = "async"
}
package enum CodexTrustUnknownReason: Equatable, Sendable {
    case unsupportedVersion(String)
    case versionUnavailable
    case stateUnreadable(path: String)
}

package enum ProviderIntegrationProblem: Equatable, Sendable {
    case homeMissing(path: String)
    case homeUnreadable(path: String, reason: String)
    case hookFileUnreadable(path: String, reason: String)
    case hookFileUnparseable(path: String, reason: String)
    case scriptUnreadable(path: String, reason: String)
    case versionUnreadable(path: String, reason: String)
    case notInstalled(path: String)
    case scriptMissing(path: String)
    case scriptOutdated(path: String, installed: Int, expected: Int)
    case legacyEntry(event: String, path: String)
    case entryMissing(event: String, path: String)
    case entryModified(event: String, path: String, aspect: ProviderHookEntryAspect)
    case codexHooksFeatureOff(path: String)
    case codexNeedsReview(event: String, key: String)
    case codexModified(event: String, key: String)
    case codexDisabled(event: String, key: String)
    case codexTrustUnknown(reason: CodexTrustUnknownReason)

    package var verdict: ProviderIntegrationVerdict {
        switch self {
        case .homeMissing, .homeUnreadable, .hookFileUnreadable, .hookFileUnparseable, .scriptUnreadable: .unavailable
        case .notInstalled: .notInstalled
        case .versionUnreadable, .scriptMissing, .scriptOutdated, .legacyEntry: .outdated
        case .entryMissing, .entryModified, .codexHooksFeatureOff: .entriesMissing
        case .codexNeedsReview, .codexModified, .codexDisabled: .notTrusted
        case .codexTrustUnknown: .trustUnknown
        }
    }
}

package enum ProviderIntegrationNote: Equatable, Sendable {
    case installedByNewerAgentStudio(installed: Int, expected: Int)
}

package struct ProviderIntegrationStatus: Equatable, Sendable {
    package let provider: AgentPackageProvider
    package let problems: [ProviderIntegrationProblem]
    package let notes: [ProviderIntegrationNote]
    package var verdict: ProviderIntegrationVerdict {
        problems.map(\.verdict).min(by: { $0.precedence < $1.precedence }) ?? .current
    }
}

extension ProviderIntegrationProblem {
    package func presentation(provider: AgentPackageProvider) -> ProviderIntegrationProblemPresentation {
        let install = "agentstudio package install \(provider.rawValue)"
        let kind: String
        var problemPath: String?
        var problemEvent: String?
        var problemKey: String?
        var problemDetail: String?
        let recovery: String
        switch self {
        case .homeMissing(let path):
            kind = "homeMissing"
            problemPath = path
            recovery = "start \(provider.rawValue) once"
        case .homeUnreadable(let path, let reason):
            kind = "homeUnreadable"
            problemPath = path
            problemDetail = reason
            recovery = Self.readRecovery(path)
        case .hookFileUnreadable(let path, let reason):
            kind = "hookFileUnreadable"
            problemPath = path
            problemDetail = reason
            recovery = Self.readRecovery(path)
        case .hookFileUnparseable(let path, let reason):
            kind = "hookFileUnparseable"
            problemPath = path
            problemDetail = reason
            recovery = "fix \(path)"
        case .scriptUnreadable(let path, let reason):
            kind = "scriptUnreadable"
            problemPath = path
            problemDetail = reason
            recovery = Self.readRecovery(path)
        case .versionUnreadable(let path, let reason):
            kind = "versionUnreadable"
            problemPath = path
            problemDetail = reason
            recovery = install
        case .notInstalled(let path):
            kind = "notInstalled"
            problemPath = path
            recovery = install
        case .scriptMissing(let path):
            kind = "scriptMissing"
            problemPath = path
            recovery = install
        case .scriptOutdated(let path, let installed, let expected):
            kind = "scriptOutdated"
            problemPath = path
            problemDetail = "installed v\(installed), expected v\(expected)"
            recovery = install
        case .legacyEntry(let event, let path):
            kind = "legacyEntry"
            problemEvent = event
            problemPath = path
            recovery = install
        case .entryMissing(let event, let path):
            kind = "entryMissing"
            problemEvent = event
            problemPath = path
            recovery = install
        case .entryModified(let event, let path, let aspect):
            kind = "entryModified"
            problemEvent = event
            problemPath = path
            problemDetail = aspect.rawValue
            recovery = install
        case .codexHooksFeatureOff(let path):
            kind = "codexHooksFeatureOff"
            problemPath = path
            recovery = install
        case .codexNeedsReview(let event, let key):
            kind = "codexNeedsReview"
            problemEvent = event
            problemKey = key
            recovery = "open Codex and review the hook in /hooks"
        case .codexModified(let event, let key):
            kind = "codexModified"
            problemEvent = event
            problemKey = key
            recovery = "open Codex and review the hook in /hooks"
        case .codexDisabled(let event, let key):
            kind = "codexDisabled"
            problemEvent = event
            problemKey = key
            recovery = "open Codex and review the hook in /hooks"
        case .codexTrustUnknown(let reason):
            return reason.presentation
        }
        return .init(
            kind: kind, path: problemPath, event: problemEvent, key: problemKey, detail: problemDetail,
            recovery: recovery)
    }

    private static func readRecovery(_ path: String) -> String {
        "make \(path) readable, then run agentstudio package status again"
    }
}

extension CodexTrustUnknownReason {
    var presentation: ProviderIntegrationProblemPresentation {
        let detail: String
        let recovery: String
        var path: String?
        switch self {
        case .unsupportedVersion(let version):
            detail = "unsupportedVersion: \(version)"
            recovery = "Agent Studio can't verify trust for Codex \(version); review hooks in Codex"
        case .versionUnavailable:
            detail = "versionUnavailable"
            recovery = "Agent Studio can't verify the Codex version; review hooks in Codex"
        case .stateUnreadable(let statePath):
            path = statePath
            detail = "stateUnreadable"
            recovery = "make \(statePath) readable, then run agentstudio package status again"
        }
        return .init(kind: "codexTrustUnknown", path: path, event: nil, key: nil, detail: detail, recovery: recovery)
    }
}

package enum ProviderIntegrationStatusRenderer {
    package static func json(_ statuses: [ProviderIntegrationStatus]) throws -> String {
        let values = statuses.map { status -> JSONValue in
            .object([
                "provider": .string(status.provider.rawValue), "verdict": .string(status.verdict.rawValue),
                "problems": .array(status.problems.map { $0.presentation(provider: status.provider).json }),
                "notes": .array(
                    status.notes.map { note in
                        switch note {
                        case .installedByNewerAgentStudio(let installed, let expected):
                            .object([
                                "kind": .string("installedByNewerAgentStudio"),
                                "detail": .string(
                                    "installed by a newer Agent Studio: v\(installed), expected v\(expected)"),
                            ])
                        }
                    }),
            ])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(values.count == 1 ? values[0] : .array(values))
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    package static func human(_ statuses: [ProviderIntegrationStatus]) -> String {
        statuses.map { status in
            let verdict: String
            switch status.verdict {
            case .current: verdict = "current"
            case .unavailable: verdict = "unavailable"
            case .notInstalled: verdict = "not installed"
            case .outdated: verdict = "outdated"
            case .entriesMissing: verdict = "entries missing"
            case .notTrusted: verdict = "not trusted"
            case .trustUnknown: verdict = "trust unknown"
            }
            let details = status.problems.map { $0.presentation(provider: status.provider).human }
            let notes = status.notes.map { _ in "  installed by a newer Agent Studio" }
            return (["\(status.provider.rawValue): \(verdict)"] + details + notes).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

package struct ProviderIntegrationProblemPresentation {
    package let kind: String
    package let path: String?
    package let event: String?
    package let key: String?
    package let detail: String?
    package let recovery: String

    package var json: JSONValue {
        var fields: [String: JSONValue] = ["kind": .string(kind), "recovery": .string(recovery)]
        if let path { fields["path"] = .string(path) }
        if let event { fields["event"] = .string(event) }
        if let key { fields["key"] = .string(key) }
        if let detail { fields["detail"] = .string(detail) }
        return .object(fields)
    }

    package var human: String {
        let location = (path ?? key ?? event).map { " (\($0))" } ?? ""
        let explanation = detail.map { "\($0); " } ?? ""
        return "  \(kind)\(location): \(explanation)\(recovery)"
    }
}
