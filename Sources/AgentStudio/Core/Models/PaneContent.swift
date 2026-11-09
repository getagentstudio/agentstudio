import AgentStudioInfrastructure
import Foundation

// MARK: - Pane Content

/// Discriminated union for the content type held by a Pane.
/// Each pane holds exactly one content type, fixed at creation.
///
/// Uses custom Codable with a `type` discriminator and `version` field for
/// forward-compatible deserialization. Unknown content types decode as
/// `.unsupported` instead of crashing, allowing older app versions to
/// load workspaces saved by newer versions.
package enum PaneContent: Hashable, Sendable {
    /// Terminal emulator content (Ghostty or zmx-backed).
    case terminal(TerminalState)
    /// Embedded web content (future: diff viewer, PR status, dev server).
    case webview(WebviewState)
    /// Bridge-backed app panel (diff viewer, code review). Design doc §15.2.
    case bridgePanel(BridgePaneState)
    /// Source code viewer (future: file review, annotations).
    case codeViewer(CodeViewerState)
    /// Placeholder for content types not recognized by this app version.
    /// Preserved on round-trip to avoid data loss.
    case unsupported(UnsupportedContent)
}

// MARK: - PaneContent + Codable

extension PaneContent: Codable {
    /// Current schema version. Bump when any variant's state shape changes.
    static let currentVersion = 3

    private enum ContentType: String, Codable {
        case terminal
        case webview
        case bridgePanel
        case codeViewer
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case version
        case state
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

        // Try to decode the type discriminator; fall back to unsupported if unknown
        guard let typeString = try? container.decode(String.self, forKey: .type),
            let contentType = ContentType(rawValue: typeString)
        else {
            // Unknown type — preserve raw JSON for round-trip
            let rawType = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
            let rawState = try container.decodeIfPresent(AnyCodableValue.self, forKey: .state)
            self = .unsupported(UnsupportedContent(type: rawType, version: version, rawState: rawState))
            return
        }

        switch contentType {
        case .terminal:
            self = .terminal(try container.decode(TerminalState.self, forKey: .state))
        case .webview:
            self = .webview(try container.decode(WebviewState.self, forKey: .state))
        case .bridgePanel:
            self = .bridgePanel(try container.decode(BridgePaneState.self, forKey: .state))
        case .codeViewer:
            self = .codeViewer(try container.decode(CodeViewerState.self, forKey: .state))
        }
        _ = version  // reserved for future state migration
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)

        switch self {
        case .terminal(let state):
            try container.encode(ContentType.terminal.rawValue, forKey: .type)
            try container.encode(state, forKey: .state)
        case .webview(let state):
            try container.encode(ContentType.webview.rawValue, forKey: .type)
            try container.encode(state, forKey: .state)
        case .bridgePanel(let state):
            try container.encode(ContentType.bridgePanel.rawValue, forKey: .type)
            try container.encode(state, forKey: .state)
        case .codeViewer(let state):
            try container.encode(ContentType.codeViewer.rawValue, forKey: .type)
            try container.encode(state, forKey: .state)
        case .unsupported(let content):
            try container.encode(content.type, forKey: .type)
            try container.encode(content.version, forKey: .version)
            try container.encodeIfPresent(content.rawState, forKey: .state)
        }
    }
}

// MARK: - Unsupported Content

/// Preserves unrecognized pane content for round-trip persistence.
package struct UnsupportedContent: Codable, Hashable, Sendable {
    package let type: String
    package let version: Int
    let rawState: AnyCodableValue?
}

// MARK: - AnyCodableValue

/// Type-erased Codable value for preserving unknown JSON structures.
package enum AnyCodableValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([Self])
    case object([String: Self])
    case null

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([Self].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: Self].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Session Provider

/// Backend provider for terminal panes.
package enum SessionProvider: String, Codable, Hashable, Sendable {
    /// Direct Ghostty surface, no session multiplexer.
    case ghostty
    /// Headless zmx backend for persistence/restore.
    case zmx
}

// MARK: - Terminal State

/// State for a terminal pane. Absorbs the former `SessionProvider` and `SessionLifetime`.
package struct TerminalState: Codable, Hashable, Sendable {
    /// Backend provider for this terminal.
    var provider: SessionProvider
    /// Lifecycle: persistent (zmx-backed) or temporary.
    var lifetime: SessionLifetime
    /// Durable session identity captured before pane insertion and reused
    /// verbatim for attach and restoration.
    package let zmxSessionID: ZmxSessionID

    package init(
        provider: SessionProvider,
        lifetime: SessionLifetime,
        zmxSessionID: ZmxSessionID
    ) {
        self.provider = provider
        self.lifetime = lifetime
        self.zmxSessionID = zmxSessionID
    }
}

// MARK: - Webview State

/// One saved browser tab.
package struct WebviewTabSnapshot: Codable, Hashable, Sendable {
    package let id: UUID
    package let url: URL
    package let title: String

    package init(id: UUID, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// State for a browser pane: its ordered tabs and which one is active.
/// Every value holds at least one tab, and the active id names one of them.
package struct WebviewState: Codable, Hashable, Sendable {
    package let tabs: [WebviewTabSnapshot]
    package let activeTabId: UUID
    package var showNavigation: Bool

    /// A browser with one new tab.
    package init(url: URL, title: String = "", showNavigation: Bool = true) {
        let tab = WebviewTabSnapshot(id: UUIDv7.generate(), url: url, title: title)
        self.tabs = [tab]
        self.activeTabId = tab.id
        self.showNavigation = showNavigation
    }

    /// Saved tabs. Returns nil when there are no tabs or the active id names none of them.
    package init?(tabs: [WebviewTabSnapshot], activeTabId: UUID, showNavigation: Bool) {
        guard tabs.contains(where: { $0.id == activeTabId }) else { return nil }
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.showNavigation = showNavigation
    }

    package var activeTab: WebviewTabSnapshot {
        guard let tab = tabs.first(where: { $0.id == activeTabId }) else {
            preconditionFailure("WebviewState active id names no tab")
        }
        return tab
    }

    /// The active tab's address.
    package var url: URL { activeTab.url }
    /// The active tab's title.
    package var title: String { activeTab.title }

    // MARK: - Canonical Decoding

    /// Decodes only the canonical shape `{tabs, activeTabId, showNavigation}`
    /// and rejects a value with no tabs or a foreign active id.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = try container.decode([WebviewTabSnapshot].self, forKey: .tabs)
        let activeTabId = try container.decode(UUID.self, forKey: .activeTabId)
        let showNavigation = try container.decode(Bool.self, forKey: .showNavigation)
        guard let state = Self(tabs: tabs, activeTabId: activeTabId, showNavigation: showNavigation) else {
            throw DecodingError.dataCorruptedError(
                forKey: .activeTabId, in: container, debugDescription: "browser state needs its active tab")
        }
        self = state
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(activeTabId, forKey: .activeTabId)
        try container.encode(showNavigation, forKey: .showNavigation)
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, activeTabId, showNavigation
    }
}

// MARK: - Code Viewer State (future)

/// State for a code viewer pane. Defined now, wired later.
package struct CodeViewerState: Codable, Hashable, Sendable {
    /// Path to the file being viewed.
    package var filePath: URL
    /// Line to scroll to (1-based).
    package var scrollToLine: Int?

    package init(filePath: URL, scrollToLine: Int?) {
        self.filePath = filePath
        self.scrollToLine = scrollToLine
    }
}
