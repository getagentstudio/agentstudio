import Foundation

public struct IPCPrincipal: Equatable, Sendable {
    public let principalId: UUID
    public let runtimeId: UUID
    public let accessMode: IPCAccessMode
    public let kind: IPCPrincipalKind
    public let approvalAuthority: IPCApprovalAuthority

    public init(
        principalId: UUID,
        runtimeId: UUID,
        accessMode: IPCAccessMode,
        kind: IPCPrincipalKind,
        approvalAuthority: IPCApprovalAuthority
    ) {
        self.principalId = principalId
        self.runtimeId = runtimeId
        self.accessMode = accessMode
        self.kind = kind
        self.approvalAuthority = approvalAuthority
    }
}

public enum IPCAccessMode: String, CaseIterable, Codable, Equatable, Sendable {
    case off
    case agentStudioOnly
    case automationSameUser
    case password
    case unsafeDebug
}

public enum IPCPrincipalKind: Equatable, Sendable {
    case spawnedPaneAgent(boundPaneId: String, boundWorkspaceId: UUID?)
    case automationClient
    case futureMCPClient
    case unsafeDebugClient
}

public enum IPCApprovalAuthority: Equatable, Sendable {
    case noApprovalAuthority
    case policyConfigured(scopes: Set<IPCApprovalScope>)
    case delegatedApprover(scopes: Set<IPCApprovalScope>)
}

public struct IPCApprovalScope: Hashable, Sendable {
    public let privilege: IPCPrivilegeClass
    public let target: IPCTargetScope
    public let dataScope: IPCDataScope

    public init(privilege: IPCPrivilegeClass, target: IPCTargetScope, dataScope: IPCDataScope) {
        self.privilege = privilege
        self.target = target
        self.dataScope = dataScope
    }
}

public enum IPCTargetScope: Hashable, Sendable, Codable {
    case selfPane
    case pane(String)
    case workspace(UUID)
    case app

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case selfPane
        case pane
        case workspace
        case app
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .selfPane:
            self = .selfPane
        case .pane:
            self = .pane(try container.decode(String.self, forKey: .value))
        case .workspace:
            self = .workspace(try container.decode(UUID.self, forKey: .value))
        case .app:
            self = .app
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selfPane:
            try container.encode(Kind.selfPane, forKey: .kind)
        case .pane(let paneId):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(paneId, forKey: .value)
        case .workspace(let workspaceId):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(workspaceId, forKey: .value)
        case .app:
            try container.encode(Kind.app, forKey: .kind)
        }
    }
}

public enum IPCDataScope: String, Codable, CaseIterable, Hashable, Sendable {
    case unspecified
    case paneContext
    case sidebarState
    case uiSurface
    case bridgeReviewPackage
    case bridgeContent
    case bridgeTelemetry
    case terminalStatus
    case terminalSnapshot
    case terminalInput
    case terminalWait
    case permissionState
    case sessionReport
    case sessionState
}

public enum IPCPrivilegeClass: String, Codable, CaseIterable, Hashable, Sendable {
    case systemRead
    case workspaceRead
    case paneContextRead
    case paneContextWrite
    case layoutMutate
    case bridgeRead
    case bridgeContentRead
    case bridgeControl
    case bridgeTelemetryRead
    case bridgeTelemetryFlush
    case terminalRead
    case terminalWrite
    case terminalStatusRead
    case terminalSnapshotRead
    case terminalInputWrite
    case terminalWait
    case eventsRead
    case uiPresent
    case permissionRequest
    case permissionRead
    case grantApprove
    case appCommandExecute
    case sidebarStateMutate
    case sessionReportWrite
    case sessionStateRead
    case debugUnsafe
}

public enum IPCExecutionOwner: String, CaseIterable, Codable, Equatable, Sendable {
    case appCommand
    case uiPresentation
    case workspaceAction
    case bridgeCapability
    case runtimeCommand
    case queryReader
    case eventReader
    case permissionBroker
    case sessionsIngest
    case paneContextService
}

public enum IPCResultSemantics: String, CaseIterable, Codable, Equatable, Sendable {
    case discriminated
    case applied
    case accepted
    case durable
    case presented
    case partial
    case uncertain
}

public enum IPCPrincipalAvailability: String, CaseIterable, Codable, Equatable, Sendable {
    case preAuthentication
    case authenticated
}

public struct IPCSchemaDescription: Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct IPCMethodDefinition: Equatable, Sendable {
    public let name: String
    public let paramsSchema: IPCSchemaDescription
    public let resultSchema: IPCSchemaDescription
    public let privilegeClasses: Set<IPCPrivilegeClass>
    public let principalAvailability: IPCPrincipalAvailability
    public let executionOwner: IPCExecutionOwner
    public let resultSemantics: IPCResultSemantics

    public init(
        name: String,
        paramsSchema: IPCSchemaDescription = IPCSchemaDescription(name: "object"),
        resultSchema: IPCSchemaDescription = IPCSchemaDescription(name: "object"),
        privilegeClasses: Set<IPCPrivilegeClass>,
        principalAvailability: IPCPrincipalAvailability = .authenticated,
        executionOwner: IPCExecutionOwner,
        resultSemantics: IPCResultSemantics
    ) throws {
        let reservedBackendPrefix = ["z", "m", "x"].joined() + "."
        guard !name.hasPrefix(reservedBackendPrefix) else {
            throw IPCMethodDefinitionError.reservedBackendNamespaceNotAllowed
        }
        guard name.contains("."), !name.hasPrefix("."), !name.hasSuffix(".") else {
            throw IPCMethodDefinitionError.invalidMethodName
        }
        guard !privilegeClasses.isEmpty else {
            throw IPCMethodDefinitionError.missingPrivilegeClass
        }

        self.name = name
        self.paramsSchema = paramsSchema
        self.resultSchema = resultSchema
        self.privilegeClasses = privilegeClasses
        self.principalAvailability = principalAvailability
        self.executionOwner = executionOwner
        self.resultSemantics = resultSemantics
    }
}

public enum IPCMethodDefinitionError: Error, Equatable, Sendable {
    case invalidMethodName
    case missingPrivilegeClass
    case reservedBackendNamespaceNotAllowed
}

public enum IPCHandleKind: String, Codable, CaseIterable, Hashable, Sendable {
    case window
    case workspace
    case repo
    case tab
    case pane
}

public enum IPCHandleReference: Hashable, Sendable {
    case friendlyOrdinal(Int)
    case canonicalUUID(UUID)
}

public struct IPCHandle: Hashable, Sendable {
    public let kind: IPCHandleKind
    public let reference: IPCHandleReference

    public init(kind: IPCHandleKind, reference: IPCHandleReference) {
        self.kind = kind
        self.reference = reference
    }

    public static func parse(_ rawValue: String) throws -> Self {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = IPCHandleKind(rawValue: String(parts[0])) else {
            throw IPCHandleError.invalidHandle
        }

        let rawReference = String(parts[1])
        if let ordinal = Int(rawReference), ordinal > 0 {
            return Self(kind: kind, reference: .friendlyOrdinal(ordinal))
        }

        if let uuid = UUID(uuidString: rawReference) {
            return Self(kind: kind, reference: .canonicalUUID(uuid))
        }

        throw IPCHandleError.invalidHandle
    }
}

public enum IPCHandleError: Error, Equatable, Sendable {
    case invalidHandle
    case targetNotFound
}

public struct IPCPermissionScope: Hashable, Sendable, Codable {
    public let privilege: IPCPrivilegeClass
    public let target: IPCTargetScope
    public let dataScope: IPCDataScope

    public init(privilege: IPCPrivilegeClass, target: IPCTargetScope, dataScope: IPCDataScope) {
        self.privilege = privilege
        self.target = target
        self.dataScope = dataScope
    }
}

public enum IPCPermissionApprovalRoute: Hashable, Sendable, Codable {
    case appPolicy
    case humanPrompt
    case delegatedPrincipal(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case principalId
    }

    private enum Kind: String, Codable {
        case appPolicy
        case humanPrompt
        case delegatedPrincipal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .appPolicy:
            self = .appPolicy
        case .humanPrompt:
            self = .humanPrompt
        case .delegatedPrincipal:
            self = .delegatedPrincipal(try container.decode(UUID.self, forKey: .principalId))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .appPolicy:
            try container.encode(Kind.appPolicy, forKey: .kind)
        case .humanPrompt:
            try container.encode(Kind.humanPrompt, forKey: .kind)
        case .delegatedPrincipal(let principalId):
            try container.encode(Kind.delegatedPrincipal, forKey: .kind)
            try container.encode(principalId, forKey: .principalId)
        }
    }
}

public enum IPCPermissionRequestState: String, CaseIterable, Codable, Equatable, Sendable {
    case pending
    case granted
    case denied
}

public struct IPCPermissionRequestParams: Codable, Equatable, Sendable {
    public let scope: IPCPermissionScope
    public let reason: String
    public let approvalRoute: IPCPermissionApprovalRoute

    public init(scope: IPCPermissionScope, reason: String, approvalRoute: IPCPermissionApprovalRoute) {
        self.scope = scope
        self.reason = reason
        self.approvalRoute = approvalRoute
    }
}

public struct IPCPermissionRequestResult: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let state: IPCPermissionRequestState
    public let principalId: UUID
    public let requestedScope: IPCPermissionScope
    public let approvalRoute: IPCPermissionApprovalRoute

    public init(
        requestId: UUID,
        state: IPCPermissionRequestState,
        principalId: UUID,
        requestedScope: IPCPermissionScope,
        approvalRoute: IPCPermissionApprovalRoute
    ) {
        self.requestId = requestId
        self.state = state
        self.principalId = principalId
        self.requestedScope = requestedScope
        self.approvalRoute = approvalRoute
    }
}

public struct IPCPermissionGrantStatusResult: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let state: IPCPermissionRequestState
    public let principalId: UUID
    public let requestedScope: IPCPermissionScope
    public let approvalRoute: IPCPermissionApprovalRoute
    public let active: Bool

    public init(
        requestId: UUID,
        state: IPCPermissionRequestState,
        principalId: UUID,
        requestedScope: IPCPermissionScope,
        approvalRoute: IPCPermissionApprovalRoute,
        active: Bool
    ) {
        self.requestId = requestId
        self.state = state
        self.principalId = principalId
        self.requestedScope = requestedScope
        self.approvalRoute = approvalRoute
        self.active = active
    }
}
