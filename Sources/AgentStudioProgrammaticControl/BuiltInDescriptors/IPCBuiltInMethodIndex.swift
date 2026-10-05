import Foundation

/// Deferred compiled recipes shared by full app composition and selective CLI resolution.
package struct IPCBuiltInMethodIndex: Sendable {
    package let entries: [IPCBuiltInMethodIndexEntry]
    private let entriesByName: [String: IPCBuiltInMethodIndexEntry]

    package init() { self.init(entries: Self.builtInEntries) }

    package init(entries: [IPCBuiltInMethodIndexEntry]) {
        self.entries = entries.sorted { $0.name < $1.name }
        entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    }

    /// Runtime-dependent result catalogs are unnecessary for help and name corrections.
    package var compositionHelp: [IPCMethodHelpProjection] {
        [
            IPCCommandMethodComposition.executeHelp, IPCCommandMethodComposition.listHelp,
            IPCSystemCapabilitiesDescriptorFactory.helpProjection,
        ]
    }

    package var methodNames: [String] { entries.map(\.name) + compositionHelp.map(\.name) }

    package func entry(named name: String) -> IPCBuiltInMethodIndexEntry? {
        entriesByName[name]
    }

    package func makeRepresentations(inputs: IPCBuiltInMethodCatalogInputs) throws
        -> [any IPCMethodDescriptorRepresentation]
    {
        try entries.map { try $0.makeRepresentation(inputs: inputs) }
    }

    private static var builtInEntries: [IPCBuiltInMethodIndexEntry] {
        [
            IPCSystemAndAuthMethodDescriptors.authLoginEntry.erased,
            IPCSystemAndAuthMethodDescriptors.authStatusEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeDiffCollapseFileEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeDiffExpandFileEntry.erased,
            IPCBridgeReviewMethodDescriptors.bridgeDiffGetPackageEntry.erased,
            IPCBridgeReviewMethodDescriptors.bridgeDiffLoadEntry.erased,
            IPCBridgeReviewMethodDescriptors.bridgeDiffRefreshEntry.erased,
            IPCBridgeReviewMethodDescriptors.bridgeDiffRenderStateEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeDiffScrollToFileEntry.erased,
            IPCBridgeReviewMethodDescriptors.bridgeDiffSelectFileEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeFileTreeRevealPathEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeFileTreeSearchEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeFileTreeSetFilterEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeFileViewGetContentEntry.erased,
            IPCBridgeReviewMethodDescriptors.bridgeFileViewOpenEntry.erased,
            IPCBridgeControlMethodDescriptors.bridgeFileViewShowMarkdownPreviewEntry.erased,
            IPCBridgeTelemetryMethodDescriptors.bridgeTelemetryFlushEntry.erased,
            IPCBridgeTelemetryMethodDescriptors.bridgeTelemetrySnapshotEntry.erased,
            IPCLayoutMethodDescriptors.drawerAddPaneEntry.erased,
            IPCLayoutMethodDescriptors.drawerToggleEntry.erased,
            IPCEventMethodDescriptors.eventsSubscribeEntry.erased,
            IPCEventMethodDescriptors.eventsUnsubscribeEntry.erased,
            IPCLayoutMethodDescriptors.paneCloseEntry.erased,
            IPCWorkspaceQueryMethodDescriptors.paneCurrentEntry.erased,
            IPCLayoutMethodDescriptors.paneFocusEntry.erased,
            IPCWorkspaceQueryMethodDescriptors.paneListEntry.erased,
            IPCWorkspaceQueryMethodDescriptors.paneSnapshotEntry.erased,
            IPCLayoutMethodDescriptors.paneSplitEntry.erased,
            IPCSessionMethodDescriptors.sessionEventEntry.erased,
            IPCSessionMethodDescriptors.sessionMessageEntry.erased,
            IPCSessionMethodDescriptors.sessionQueryEntry.erased,
            IPCSessionMethodDescriptors.sessionReportEntry.erased,
            IPCPresentationAndSidebarMethodDescriptors.sidebarGroupingGetEntry.erased,
            IPCPresentationAndSidebarMethodDescriptors.sidebarSurfaceGetEntry.erased,
            IPCSystemAndAuthMethodDescriptors.systemIdentifyEntry.erased,
            IPCSystemAndAuthMethodDescriptors.systemPingEntry.erased,
            IPCSystemAndAuthMethodDescriptors.systemVersionEntry.erased,
            IPCTerminalMethodDescriptors.terminalSendEntry.erased,
            IPCTerminalMethodDescriptors.terminalSnapshotEntry.erased,
            IPCTerminalMethodDescriptors.terminalStatusEntry.erased,
            IPCTerminalMethodDescriptors.terminalWaitEntry.erased,
            IPCPresentationAndSidebarMethodDescriptors.uiArrangementsOpenEntry.erased,
            IPCPresentationAndSidebarMethodDescriptors.uiCommandBarOpenEntry.erased,
            IPCWorkspaceQueryMethodDescriptors.windowCurrentEntry.erased,
            IPCWorkspaceQueryMethodDescriptors.windowListEntry.erased,
            IPCWorkspaceQueryMethodDescriptors.workspaceCurrentEntry.erased,
            IPCWorkspaceQueryMethodDescriptors.workspaceListEntry.erased,
        ]
    }
}
