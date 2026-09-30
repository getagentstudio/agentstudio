import Foundation

enum IPCRequestSchemaFields {
    static let paneSelector = IPCJSONSchema.string(
        pattern:
            "^(?:self|pane:[1-9][0-9]*|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"
    )

    static func pane(_ name: String = "handle") -> IPCObjectField {
        .init(
            name: name,
            description: "Authenticated self pane, canonical pane UUID, or workspace-local pane:N ordinal",
            schema: paneSelector
        )
    }

    /// Model calls supply no targeting: the CLI and app own it. A defaulted
    /// self handle keeps those invocations free of a typed pane identifier
    /// while tooling callers may still name an explicit pane.
    static func paneDefaultingToSelf(_ name: String = "handle") throws -> IPCObjectField {
        .init(
            name: name,
            description: "Authenticated self pane, canonical pane UUID, or workspace-local pane:N ordinal",
            schema: paneSelector,
            presence: try .defaulted("self")
        )
    }

    static let correlation = IPCObjectField(
        name: "correlationId", description: "Logical mutation UUID retained unchanged across retries",
        schema: IPCSchemaScalars.uuid
    )

    static let item = IPCObjectField(
        name: "itemId", description: "Item identifier from the target Bridge pane's current package",
        schema: .string(minimumLength: 1)
    )

    static func itemMutation() -> IPCJSONSchema {
        .object(fields: [pane(), item, correlation])
    }

    static func worktreeOpen() -> IPCJSONSchema {
        .object(fields: [
            .init(name: "worktreeId", description: "Explicit destination worktree UUID", schema: IPCSchemaScalars.uuid),
            correlation,
        ])
    }
}

extension IPCPaneSplitParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "direction", description: "Side of the new pane", schema: try IPCPaneSplitDirection.ipcSchema()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCPaneCloseParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [IPCRequestSchemaFields.pane(), IPCRequestSchemaFields.correlation])
    }
}

extension IPCDrawerAddPaneParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane("parentPaneHandle"),
            .optional(
                "content", description: "New drawer child content; omission adds a terminal",
                schema: try IPCDrawerChildContent.ipcSchema()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCDrawerChildContent: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            kindOnly("terminal", "A terminal drawer child"),
            .object(fields: [
                .init(name: "kind", description: "A browser drawer child", schema: .string(allowedValues: ["browser"])),
                .init(
                    name: "url", description: "Absolute http or https URL to open", schema: .string(minimumLength: 1)),
            ]),
            kindOnly("bridge", "Bridge content; always refused in a drawer"),
            kindOnly("codeViewer", "Code-viewer content; always refused in a drawer"),
        ])
    }

    private static func kindOnly(_ kind: String, _ description: String) -> IPCJSONSchema {
        .object(fields: [.init(name: "kind", description: description, schema: .string(allowedValues: [kind]))])
    }
}

extension IPCDrawerToggleParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [IPCRequestSchemaFields.pane("parentPaneHandle"), IPCRequestSchemaFields.correlation])
    }
}

extension IPCBridgePaneParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [IPCRequestSchemaFields.pane()])
    }
}

extension IPCBridgeReviewOpenParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        IPCRequestSchemaFields.worktreeOpen()
    }
}

extension IPCBridgeFileViewOpenParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        IPCRequestSchemaFields.worktreeOpen()
    }
}

extension IPCBridgeReviewRefreshParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [IPCRequestSchemaFields.pane(), IPCRequestSchemaFields.correlation])
    }
}

extension IPCBridgeReviewSelectFileParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema { IPCRequestSchemaFields.itemMutation() }
}

extension IPCBridgeDiffScrollToFileParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema { IPCRequestSchemaFields.itemMutation() }
}

extension IPCBridgeDiffExpandFileParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema { IPCRequestSchemaFields.itemMutation() }
}

extension IPCBridgeDiffCollapseFileParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema { IPCRequestSchemaFields.itemMutation() }
}

extension IPCBridgeFileTreeSearchParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "searchText",
                description: "Exact search text, at most 4096 UTF-16 code units; empty clears search",
                schema: .string(
                    maximumLength: maximumSearchTextUTF16Length,
                    maximumUTF16Length: maximumSearchTextUTF16Length
                )
            ),
            .init(
                name: "searchMode", description: "Text or regular-expression matching",
                schema: try IPCBridgeReviewSearchMode.ipcSchema(),
                presence: try .defaulted(IPCBridgeReviewSearchMode.text)
            ),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCBridgeFileTreeRevealPathParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(name: "path", description: "Path to reveal in the target pane's file tree", schema: .string()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCBridgeFileViewShowMarkdownPreviewParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .optional(
                "itemId", description: "Explicit item, or the pane's currently selected item when omitted",
                schema: .string()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCBridgeContentGetParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "contentHandleId", description: "Content handle from the target pane's package",
                schema: .string(minimumLength: 1)),
            .init(
                name: "reviewGeneration", description: "Exact package generation owning the content handle",
                schema: .integer(minimum: 0)),
        ])
    }
}

extension IPCBridgeFileTreeFilterCandidate: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        let category = IPCObjectField(
            name: "categoryFilter", description: "File category to include",
            schema: try IPCBridgeFilterCategory.ipcSchema()
        )
        return .oneOf([
            .object(fields: [
                .init(name: "surface", description: "Files filter variant", schema: .string(allowedValues: ["files"])),
                category,
            ]),
            .object(fields: [
                .init(
                    name: "surface", description: "Review filter variant", schema: .string(allowedValues: ["review"])),
                .init(
                    name: "gitStatusFilter", description: "Git change status to include",
                    schema: try IPCBridgeGitStatusFilter.ipcSchema()),
                category,
                .init(name: "showBinary", description: "Include binary items", schema: .boolean),
                .init(name: "showLarge", description: "Include large items", schema: .boolean),
            ]),
        ])
    }
}

extension IPCBridgeFileTreeSetFilterParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "candidate", description: "Complete filter for one explicit surface",
                schema: try IPCBridgeFileTreeFilterCandidate.ipcSchema()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCSidebarGroupingGetParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "surface", description: "Sidebar surface to query", schema: try IPCSidebarSurface.ipcSchema())
        ])
    }
}

extension IPCSidebarSurfaceGetParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema { .object(fields: []) }
}

extension IPCCommandBarOpenParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "workspaceWindowId", description: "Explicit owning workspace window UUID",
                schema: IPCSchemaScalars.uuid),
            .init(name: "scope", description: "Command-bar root scope", schema: try IPCCommandBarScope.ipcSchema()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCArrangementsOpenParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "workspaceWindowId", description: "Explicit owning workspace window UUID",
                schema: IPCSchemaScalars.uuid),
            .optional(
                "targetPaneHandle", description: "Pane context within the selected window",
                schema: IPCRequestSchemaFields.paneSelector),
            IPCRequestSchemaFields.correlation,
        ])
    }
}
