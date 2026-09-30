import Foundation

extension IPCAccessMode: IPCSchemaProviding {}
extension IPCPaneContentKind: IPCSchemaProviding {}
extension IPCPaneResidency: IPCSchemaProviding {}
extension IPCPaneSplitDirection: IPCSchemaProviding {}
extension IPCRuntimeLifecycle: IPCSchemaProviding {}
extension IPCExecutionBackendKind: IPCSchemaProviding {}
extension IPCTerminalSendDisposition: IPCSchemaProviding {}
extension IPCTerminalWaitCondition: IPCSchemaProviding {}

extension IPCSystemIdentifyResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "runtimeId", description: "Application runtime UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "accessMode", description: "Active IPC access mode", schema: try IPCAccessMode.ipcSchema()),
            .init(name: "appVersion", description: "Agent Studio application version", schema: .string()),
        ])
    }
}

extension IPCSystemVersionResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "appVersion", description: "Agent Studio application version", schema: .string())
        ])
    }
}

extension IPCWindowSummary: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "Canonical window UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "ordinal", description: "One-based friendly window ordinal", schema: .integer(minimum: 1)),
            .init(name: "isKey", description: "Whether this is the key macOS window", schema: .boolean),
            .init(name: "isFocused", description: "Whether the window currently owns focus", schema: .boolean),
            .init(name: "isCurrent", description: "Whether this is the current IPC window", schema: .boolean),
            .init(
                name: "workspaceId", description: "Workspace UUID hosted by the window", schema: IPCSchemaScalars.uuid),
        ])
    }
}

extension IPCWindowListResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "windows", description: "Known workspace windows",
                schema: .array(items: try IPCWindowSummary.ipcSchema()))
        ])
    }
}

extension IPCCurrentWindowResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "window", description: "Current workspace window", schema: try IPCWindowSummary.ipcSchema())
        ])
    }
}

extension IPCWorkspaceWorktreeSummary: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "Canonical worktree UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "repoId", description: "Owning repository UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "name", description: "Worktree display name", schema: .string()),
            .init(name: "path", description: "Absolute worktree filesystem path", schema: .string()),
            .init(
                name: "isMainWorktree", description: "Whether this is the repository main worktree", schema: .boolean),
        ])
    }
}

extension IPCWorkspaceRepositorySummary: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "Canonical repository UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "name", description: "Repository display name", schema: .string()),
            .init(name: "path", description: "Absolute repository filesystem path", schema: .string()),
            .init(
                name: "worktrees", description: "Worktrees belonging to the repository",
                schema: .array(items: try IPCWorkspaceWorktreeSummary.ipcSchema())),
        ])
    }
}

extension IPCWorkspaceSummary: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "Canonical workspace UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "ordinal", description: "One-based friendly workspace ordinal", schema: .integer(minimum: 1)),
            .init(name: "name", description: "Workspace display name", schema: .string()),
            .init(name: "tabCount", description: "Number of tabs in the workspace", schema: .integer(minimum: 0)),
            .init(name: "paneCount", description: "Number of panes in the workspace", schema: .integer(minimum: 0)),
            .init(
                name: "repositories", description: "Repositories attached to the workspace",
                schema: .array(items: try IPCWorkspaceRepositorySummary.ipcSchema())),
            .init(name: "isCurrent", description: "Whether this is the current workspace", schema: .boolean),
        ])
    }
}

extension IPCWorkspaceListResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "workspaces", description: "Known workspaces",
                schema: .array(items: try IPCWorkspaceSummary.ipcSchema()))
        ])
    }
}

extension IPCCurrentWorkspaceResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "workspace", description: "Current workspace", schema: try IPCWorkspaceSummary.ipcSchema())
        ])
    }
}

extension IPCTabSummary: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "Canonical tab UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "ordinal", description: "One-based friendly tab ordinal", schema: .integer(minimum: 1)),
            .init(name: "name", description: "Tab display name", schema: .string()),
            .init(
                name: "paneIds", description: "Pane UUIDs in tab order", schema: .array(items: IPCSchemaScalars.uuid)),
            .optional(
                "activePaneId", description: "Active pane UUID when the tab has one", schema: IPCSchemaScalars.uuid),
            .init(name: "isActive", description: "Whether this is the active tab", schema: .boolean),
        ])
    }
}

extension IPCPaneSummary: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "Canonical pane UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "ordinal", description: "One-based friendly pane ordinal", schema: .integer(minimum: 1)),
            .init(
                name: "contentKind", description: "Content hosted by the pane",
                schema: try IPCPaneContentKind.ipcSchema()),
            .init(name: "residency", description: "Pane lifecycle residency", schema: try IPCPaneResidency.ipcSchema()),
            .optional("tabId", description: "Owning tab UUID when tab-resident", schema: IPCSchemaScalars.uuid),
            .optional("repoId", description: "Associated repository UUID", schema: IPCSchemaScalars.uuid),
            .optional("worktreeId", description: "Associated worktree UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "isActive", description: "Whether this pane is active", schema: .boolean),
            .init(name: "isDrawerChild", description: "Whether this pane is hosted in a drawer", schema: .boolean),
        ])
    }
}

extension IPCPaneListResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "panes", description: "Known panes", schema: .array(items: try IPCPaneSummary.ipcSchema()))
        ])
    }
}

extension IPCPaneSnapshotResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "pane", description: "Resolved pane snapshot", schema: try IPCPaneSummary.ipcSchema()),
            .optional(
                "tab", description: "Owning tab when the pane is tab-resident", schema: try IPCTabSummary.ipcSchema()),
            .init(
                name: "workspace", description: "Workspace containing the pane",
                schema: try IPCWorkspaceSummary.ipcSchema()),
        ])
    }
}

extension IPCPaneFocusResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        try paneBooleanResult(field: "focused", meaning: "Whether focus was applied")
    }
}

extension IPCPaneSplitResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "targetPaneId", description: "UUID of the newly created pane", schema: IPCSchemaScalars.uuid),
            .init(
                name: "direction", description: "Side of the source pane used for the split",
                schema: try IPCPaneSplitDirection.ipcSchema()),
            correlationField(),
        ])
    }
}

extension IPCPaneCloseResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        paneCorrelationResult(idField: "paneId", description: "UUID of the closed pane")
    }
}

extension IPCDrawerAddPaneResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "parentPaneId", description: "UUID of the drawer parent pane", schema: IPCSchemaScalars.uuid),
            .init(name: "childPaneId", description: "UUID of the new drawer child", schema: IPCSchemaScalars.uuid),
            .init(
                name: "childHandle", description: "Selector that targets the new drawer child in later calls",
                schema: IPCSchemaScalars.uuid),
            correlationField(),
        ])
    }
}

extension IPCDrawerToggleResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        paneCorrelationResult(idField: "parentPaneId", description: "UUID of the drawer parent pane")
    }
}

extension IPCTerminalStatusResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(
            fields: try terminalIdentityFields() + [
                .init(name: "isReady", description: "Whether the terminal runtime accepts work", schema: .boolean)
            ])
    }
}

extension IPCTerminalSnapshotResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(
            fields: try terminalIdentityFields() + [
                .init(
                    name: "lastSequence", description: "Latest observed terminal event sequence",
                    schema: IPCSchemaScalars.unsignedInteger),
                .init(
                    name: "timestamp",
                    description: "Snapshot time in seconds since the Foundation reference date",
                    schema: .number()),
                .optional("rendererHealthy", description: "Renderer health when known", schema: .boolean),
                .optional("readOnly", description: "Whether the terminal is read-only when known", schema: .boolean),
                .optional("secureInput", description: "Whether secure input is active when known", schema: .boolean),
            ])
    }
}

extension IPCTerminalSendInputResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "paneId", description: "Target terminal pane UUID", schema: IPCSchemaScalars.uuid),
            .init(
                name: "commandId", description: "Server-assigned terminal command UUID", schema: IPCSchemaScalars.uuid),
            correlationField(),
            .init(
                name: "disposition", description: "Input admission disposition",
                schema: try IPCTerminalSendDisposition.ipcSchema()),
            .optional(
                "queuePosition", description: "Zero-based queue position when queued", schema: .integer(minimum: 0)),
        ])
    }
}

extension IPCTerminalWaitResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "paneId", description: "Observed terminal pane UUID", schema: IPCSchemaScalars.uuid),
            .init(
                name: "condition", description: "Condition that completed the wait",
                schema: try IPCTerminalWaitCondition.ipcSchema()),
            .init(
                name: "eventName", description: "Runtime event satisfying the wait",
                schema: try IPCEventName.ipcSchema()),
            .optional("commandId", description: "Related terminal command UUID", schema: IPCSchemaScalars.uuid),
            correlationField(),
            .optional(
                "exitCode", description: "Process exit code when the command finished",
                schema: IPCSchemaScalars.signedInteger),
            .optional(
                "duration", description: "Observed duration in nanoseconds", schema: IPCSchemaScalars.unsignedInteger),
            .optional("healthy", description: "Renderer health outcome when requested", schema: .boolean),
        ])
    }
}

private func correlationField() -> IPCObjectField {
    .optional("correlationId", description: "Caller correlation UUID when supplied", schema: IPCSchemaScalars.uuid)
}

private func paneCorrelationResult(idField: String, description: String) -> IPCJSONSchema {
    .object(fields: [
        .init(name: idField, description: description, schema: IPCSchemaScalars.uuid),
        correlationField(),
    ])
}

private func paneBooleanResult(field: String, meaning: String) throws -> IPCJSONSchema {
    .object(fields: [
        .init(name: "paneId", description: "Target pane UUID", schema: IPCSchemaScalars.uuid),
        .init(name: field, description: meaning, schema: .boolean),
    ])
}

private func terminalIdentityFields() throws -> [IPCObjectField] {
    [
        .init(name: "paneId", description: "Terminal pane UUID", schema: IPCSchemaScalars.uuid),
        .init(name: "lifecycle", description: "Runtime lifecycle state", schema: try IPCRuntimeLifecycle.ipcSchema()),
        .init(name: "backend", description: "Execution backend kind", schema: try IPCExecutionBackendKind.ipcSchema()),
        .init(name: "capabilities", description: "Runtime capability identifiers", schema: .array(items: .string())),
    ]
}
