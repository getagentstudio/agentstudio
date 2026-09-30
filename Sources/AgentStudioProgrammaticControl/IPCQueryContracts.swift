import Foundation

public struct IPCSystemIdentifyResult: Codable, Equatable, Sendable {
    public let runtimeId: UUID
    public let accessMode: IPCAccessMode
    public let appVersion: String

    public init(runtimeId: UUID, accessMode: IPCAccessMode, appVersion: String) {
        self.runtimeId = runtimeId
        self.accessMode = accessMode
        self.appVersion = appVersion
    }
}

public struct IPCSystemVersionResult: Codable, Equatable, Sendable {
    public let appVersion: String

    public init(appVersion: String) {
        self.appVersion = appVersion
    }
}

public struct IPCMethodCapability: Codable, Equatable, Sendable {
    public let name: String
    public let privilegeClasses: [IPCPrivilegeClass]
    public let principalAvailability: IPCPrincipalAvailability
    public let executionOwner: IPCExecutionOwner
    public let resultSemantics: IPCResultSemantics

    public init(
        name: String,
        privilegeClasses: [IPCPrivilegeClass],
        principalAvailability: IPCPrincipalAvailability,
        executionOwner: IPCExecutionOwner,
        resultSemantics: IPCResultSemantics
    ) {
        self.name = name
        self.privilegeClasses = privilegeClasses
        self.principalAvailability = principalAvailability
        self.executionOwner = executionOwner
        self.resultSemantics = resultSemantics
    }
}

public struct IPCSystemCapabilitiesResult: Codable, Equatable, Sendable {
    public let methods: [IPCMethodCapability]

    public init(methods: [IPCMethodCapability]) {
        self.methods = methods
    }
}

public struct IPCWindowSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let ordinal: Int
    public let isKey: Bool
    public let isFocused: Bool
    public let isCurrent: Bool
    public let workspaceId: UUID

    public init(id: UUID, ordinal: Int, isKey: Bool, isFocused: Bool, isCurrent: Bool, workspaceId: UUID) {
        self.id = id
        self.ordinal = ordinal
        self.isKey = isKey
        self.isFocused = isFocused
        self.isCurrent = isCurrent
        self.workspaceId = workspaceId
    }
}

public struct IPCWindowListResult: Codable, Equatable, Sendable {
    public let windows: [IPCWindowSummary]

    public init(windows: [IPCWindowSummary]) {
        self.windows = windows
    }
}

public struct IPCCurrentWindowResult: Codable, Equatable, Sendable {
    public let window: IPCWindowSummary

    public init(window: IPCWindowSummary) {
        self.window = window
    }
}

public struct IPCWorkspaceSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let ordinal: Int
    public let name: String
    public let tabCount: Int
    public let paneCount: Int
    public let repositories: [IPCWorkspaceRepositorySummary]
    public let isCurrent: Bool

    public init(
        id: UUID,
        ordinal: Int,
        name: String,
        tabCount: Int,
        paneCount: Int,
        repositories: [IPCWorkspaceRepositorySummary] = [],
        isCurrent: Bool
    ) {
        self.id = id
        self.ordinal = ordinal
        self.name = name
        self.tabCount = tabCount
        self.paneCount = paneCount
        self.repositories = repositories
        self.isCurrent = isCurrent
    }
}

public struct IPCWorkspaceRepositorySummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let worktrees: [IPCWorkspaceWorktreeSummary]

    public init(id: UUID, name: String, path: String, worktrees: [IPCWorkspaceWorktreeSummary]) {
        self.id = id
        self.name = name
        self.path = path
        self.worktrees = worktrees
    }
}

public struct IPCWorkspaceWorktreeSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let repoId: UUID
    public let name: String
    public let path: String
    public let isMainWorktree: Bool

    public init(id: UUID, repoId: UUID, name: String, path: String, isMainWorktree: Bool) {
        self.id = id
        self.repoId = repoId
        self.name = name
        self.path = path
        self.isMainWorktree = isMainWorktree
    }
}

public struct IPCWorkspaceListResult: Codable, Equatable, Sendable {
    public let workspaces: [IPCWorkspaceSummary]

    public init(workspaces: [IPCWorkspaceSummary]) {
        self.workspaces = workspaces
    }
}

public struct IPCCurrentWorkspaceResult: Codable, Equatable, Sendable {
    public let workspace: IPCWorkspaceSummary

    public init(workspace: IPCWorkspaceSummary) {
        self.workspace = workspace
    }
}

public struct IPCTabSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let ordinal: Int
    public let name: String
    public let paneIds: [UUID]
    public let activePaneId: UUID?
    public let isActive: Bool

    public init(id: UUID, ordinal: Int, name: String, paneIds: [UUID], activePaneId: UUID?, isActive: Bool) {
        self.id = id
        self.ordinal = ordinal
        self.name = name
        self.paneIds = paneIds
        self.activePaneId = activePaneId
        self.isActive = isActive
    }
}

public enum IPCPaneContentKind: String, CaseIterable, Codable, Equatable, Sendable {
    case terminal
    case webview
    case bridgePanel
    case codeViewer
    case unsupported
}

public enum IPCPaneResidency: String, CaseIterable, Codable, Equatable, Sendable {
    case active
    case pendingUndo
    case backgrounded
    case orphaned
}

public struct IPCPaneSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let ordinal: Int
    public let contentKind: IPCPaneContentKind
    public let residency: IPCPaneResidency
    public let tabId: UUID?
    public let repoId: UUID?
    public let worktreeId: UUID?
    public let isActive: Bool
    public let isDrawerChild: Bool

    public init(
        id: UUID,
        ordinal: Int,
        contentKind: IPCPaneContentKind,
        residency: IPCPaneResidency,
        tabId: UUID?,
        repoId: UUID?,
        worktreeId: UUID?,
        isActive: Bool,
        isDrawerChild: Bool
    ) {
        self.id = id
        self.ordinal = ordinal
        self.contentKind = contentKind
        self.residency = residency
        self.tabId = tabId
        self.repoId = repoId
        self.worktreeId = worktreeId
        self.isActive = isActive
        self.isDrawerChild = isDrawerChild
    }
}

public struct IPCPaneListResult: Codable, Equatable, Sendable {
    public let panes: [IPCPaneSummary]

    public init(panes: [IPCPaneSummary]) {
        self.panes = panes
    }
}

public struct IPCPaneSnapshotResult: Codable, Equatable, Sendable {
    public let pane: IPCPaneSummary
    public let tab: IPCTabSummary?
    public let workspace: IPCWorkspaceSummary

    public init(pane: IPCPaneSummary, tab: IPCTabSummary?, workspace: IPCWorkspaceSummary) {
        self.pane = pane
        self.tab = tab
        self.workspace = workspace
    }
}

public struct IPCPaneFocusResult: Codable, Equatable, Sendable {
    public let paneId: UUID
    public let focused: Bool

    public init(paneId: UUID, focused: Bool) {
        self.paneId = paneId
        self.focused = focused
    }
}

public enum IPCPaneSplitDirection: String, CaseIterable, Codable, Equatable, Sendable {
    case left
    case right
}

public struct IPCPaneSplitParams: Codable, Equatable, Sendable {
    public let handle: String
    public let direction: IPCPaneSplitDirection
    public let correlationId: UUID?

    public init(handle: String, direction: IPCPaneSplitDirection, correlationId: UUID?) {
        self.handle = handle
        self.direction = direction
        self.correlationId = correlationId
    }
}

public struct IPCPaneSplitResult: Codable, Equatable, Sendable {
    public let targetPaneId: UUID
    public let direction: IPCPaneSplitDirection
    public let correlationId: UUID?

    public init(targetPaneId: UUID, direction: IPCPaneSplitDirection, correlationId: UUID?) {
        self.targetPaneId = targetPaneId
        self.direction = direction
        self.correlationId = correlationId
    }
}

public struct IPCPaneCloseParams: Codable, Equatable, Sendable {
    public let handle: String
    public let correlationId: UUID?

    public init(handle: String, correlationId: UUID?) {
        self.handle = handle
        self.correlationId = correlationId
    }
}

public struct IPCPaneCloseResult: Codable, Equatable, Sendable {
    public let paneId: UUID
    public let correlationId: UUID?

    public init(paneId: UUID, correlationId: UUID?) {
        self.paneId = paneId
        self.correlationId = correlationId
    }
}

/// What a new drawer child holds. Drawers hold terminals and browsers only;
/// Bridge and code-viewer requests are named so they can be refused, never
/// created.
public enum IPCDrawerChildContent: Codable, Equatable, Sendable {
    case terminal
    case browser(url: String)
    case bridge
    case codeViewer

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
    }

    private enum Kind: String, Codable {
        case terminal
        case browser
        case bridge
        case codeViewer
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .terminal: self = .terminal
        case .browser: self = .browser(url: try container.decode(String.self, forKey: .url))
        case .bridge: self = .bridge
        case .codeViewer: self = .codeViewer
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal:
            try container.encode(Kind.terminal, forKey: .kind)
        case .browser(let url):
            try container.encode(Kind.browser, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .bridge:
            try container.encode(Kind.bridge, forKey: .kind)
        case .codeViewer:
            try container.encode(Kind.codeViewer, forKey: .kind)
        }
    }

    /// The browser URL a drawer child may open: an absolute http or https URL
    /// with a host. `nil` for anything else, before any pane is created.
    public var admissibleBrowserURL: URL? {
        guard case .browser(let rawURL) = self,
            let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host()?.isEmpty == false
        else { return nil }
        return url
    }
}

public struct IPCDrawerAddPaneParams: Codable, Equatable, Sendable {
    public let parentPaneHandle: String
    /// Absent means a terminal.
    public let content: IPCDrawerChildContent?
    public let correlationId: UUID?

    public init(parentPaneHandle: String, content: IPCDrawerChildContent? = nil, correlationId: UUID?) {
        self.parentPaneHandle = parentPaneHandle
        self.content = content
        self.correlationId = correlationId
    }
}

public struct IPCDrawerAddPaneResult: Codable, Equatable, Sendable {
    public let parentPaneId: UUID
    public let childPaneId: UUID
    /// Selector that targets the new drawer child in later calls.
    public let childHandle: String
    public let correlationId: UUID?

    public init(parentPaneId: UUID, childPaneId: UUID, correlationId: UUID?) {
        self.parentPaneId = parentPaneId
        self.childPaneId = childPaneId
        self.childHandle = childPaneId.uuidString
        self.correlationId = correlationId
    }
}

public struct IPCDrawerToggleParams: Codable, Equatable, Sendable {
    public let parentPaneHandle: String
    public let correlationId: UUID?

    public init(parentPaneHandle: String, correlationId: UUID?) {
        self.parentPaneHandle = parentPaneHandle
        self.correlationId = correlationId
    }
}

public struct IPCDrawerToggleResult: Codable, Equatable, Sendable {
    public let parentPaneId: UUID
    public let correlationId: UUID?

    public init(parentPaneId: UUID, correlationId: UUID?) {
        self.parentPaneId = parentPaneId
        self.correlationId = correlationId
    }
}

public enum IPCRuntimeLifecycle: String, CaseIterable, Codable, Equatable, Sendable {
    case created
    case ready
    case draining
    case terminated
}

public enum IPCExecutionBackendKind: String, CaseIterable, Codable, Equatable, Sendable {
    case local
    case docker
    case gondolin
    case remote
}

public struct IPCTerminalStatusResult: Codable, Equatable, Sendable {
    public let paneId: UUID
    public let lifecycle: IPCRuntimeLifecycle
    public let isReady: Bool
    public let backend: IPCExecutionBackendKind
    public let capabilities: [String]

    public init(
        paneId: UUID,
        lifecycle: IPCRuntimeLifecycle,
        isReady: Bool,
        backend: IPCExecutionBackendKind,
        capabilities: [String]
    ) {
        self.paneId = paneId
        self.lifecycle = lifecycle
        self.isReady = isReady
        self.backend = backend
        self.capabilities = capabilities
    }
}

public struct IPCTerminalSnapshotResult: Codable, Equatable, Sendable {
    public let paneId: UUID
    public let lifecycle: IPCRuntimeLifecycle
    public let backend: IPCExecutionBackendKind
    public let capabilities: [String]
    public let lastSequence: UInt64
    public let timestamp: Date
    public let rendererHealthy: Bool?
    public let readOnly: Bool?
    public let secureInput: Bool?

    public init(
        paneId: UUID,
        lifecycle: IPCRuntimeLifecycle,
        backend: IPCExecutionBackendKind,
        capabilities: [String],
        lastSequence: UInt64,
        timestamp: Date,
        rendererHealthy: Bool?,
        readOnly: Bool?,
        secureInput: Bool?
    ) {
        self.paneId = paneId
        self.lifecycle = lifecycle
        self.backend = backend
        self.capabilities = capabilities
        self.lastSequence = lastSequence
        self.timestamp = timestamp
        self.rendererHealthy = rendererHealthy
        self.readOnly = readOnly
        self.secureInput = secureInput
    }
}

public enum IPCTerminalSendDisposition: String, CaseIterable, Codable, Equatable, Sendable {
    case accepted
    case queued
}

public struct IPCTerminalSendInputResult: Codable, Equatable, Sendable {
    public let paneId: UUID
    public let commandId: UUID
    public let correlationId: UUID?
    public let disposition: IPCTerminalSendDisposition
    public let queuePosition: Int?

    public init(
        paneId: UUID,
        commandId: UUID,
        correlationId: UUID?,
        disposition: IPCTerminalSendDisposition,
        queuePosition: Int?
    ) {
        self.paneId = paneId
        self.commandId = commandId
        self.correlationId = correlationId
        self.disposition = disposition
        self.queuePosition = queuePosition
    }
}

public enum IPCTerminalWaitCondition: String, CaseIterable, Codable, Equatable, Sendable {
    case attachReady
    case commandFinished
    case rendererHealthy
    case titleChanged
    case cwdChanged
    case progressChanged
}

public struct IPCTerminalWaitResult: Codable, Equatable, Sendable {
    public let paneId: UUID
    public let condition: IPCTerminalWaitCondition
    public let eventName: IPCEventName
    public let commandId: UUID?
    public let correlationId: UUID?
    public let exitCode: Int?
    public let duration: UInt64?
    public let healthy: Bool?

    public init(
        paneId: UUID,
        condition: IPCTerminalWaitCondition,
        eventName: IPCEventName,
        commandId: UUID?,
        correlationId: UUID?,
        exitCode: Int?,
        duration: UInt64?,
        healthy: Bool?
    ) {
        self.paneId = paneId
        self.condition = condition
        self.eventName = eventName
        self.commandId = commandId
        self.correlationId = correlationId
        self.exitCode = exitCode
        self.duration = duration
        self.healthy = healthy
    }
}
