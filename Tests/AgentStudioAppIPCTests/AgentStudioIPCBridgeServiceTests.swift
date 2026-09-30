import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio IPC Bridge service", .serialized, BridgeLiveServerFixtureTrait(configuration: .unsafeBridge))
struct AgentStudioIPCBridgeServiceTests {
    @Test("debug unsafe no-auth refreshes Bridge diff package")
    func debugUnsafeNoAuthRefreshesBridgeDiffPackage() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let correlationId = UUID()
        let fixture = scoped.fixture

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(65),
                method: "bridge.diff.refresh",
                params: .object([
                    "handle": .string("pane:1"),
                    "correlationId": .string(correlationId.uuidString),
                ])
            )
        )

        #expect(response.id == .number(65))
        #expect(response.error == nil)
        let result = try decodeResponseResult(IPCBridgeReviewRefreshResult.self, from: response)
        #expect(result.paneId == paneId)
        #expect(result.refreshed == true)
        #expect(result.status == "ready")
        #expect(result.packageId == "package-test")
        #expect(result.correlationId == correlationId)
    }

    @Test("debug unsafe no-auth opens Bridge file view")
    func debugUnsafeNoAuthOpensBridgeFileView() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let worktreeId = UUID()
        let correlationId = UUID()
        let fixture = scoped.fixture

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(64),
                method: "bridge.fileView.open",
                params: .object([
                    "worktreeId": .string(worktreeId.uuidString),
                    "correlationId": .string(correlationId.uuidString),
                ])
            )
        )

        #expect(response.id == .number(64))
        #expect(response.error == nil)
        let result = try decodeResponseResult(IPCBridgeFileViewOpenResult.self, from: response)
        #expect(result.paneId == paneId)
        #expect(result.handle == "pane:\(paneId.uuidString)")
        #expect(result.correlationId == correlationId)
    }

    @Test("debug unsafe no-auth serves Bridge package status and file view descriptor methods")
    func debugUnsafeNoAuthServesBridgePackageStatusAndFileViewDescriptorMethods() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let fixture = scoped.fixture

        let packageResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(66),
                method: "bridge.diff.getPackage",
                params: .object(["handle": .string("pane:1")])
            )
        )

        #expect(packageResponse.id == .number(66))
        #expect(packageResponse.error == nil)
        let package = try decodeResponseResult(IPCBridgeReviewPackageResult.self, from: packageResponse)
        #expect(package.paneId == paneId)
        #expect(package.packageId == "package-test")
        #expect(package.reviewGeneration == 1)
        #expect(package.items.isEmpty)

        let contentResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(67),
                method: "bridge.fileView.getContent",
                params: .object([
                    "handle": .string("pane:1"),
                    "contentHandleId": .string("handle-head"),
                    "reviewGeneration": .number(1),
                ])
            )
        )

        #expect(contentResponse.id == .number(67))
        #expect(contentResponse.error == nil)
        let content = try decodeResponseResult(IPCBridgeContentGetResult.self, from: contentResponse)
        #expect(content.paneId == paneId)
        #expect(content.handle.handleId == "handle-head")
        #expect(content.handle.mimeType == "text/x-swift")
        #expect(content.byteCount == 14)
    }

    @Test("debug unsafe no-auth serves Bridge render state method")
    func debugUnsafeNoAuthServesBridgeRenderStateMethod() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let fixture = scoped.fixture

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(71),
                method: "bridge.diff.renderState",
                params: .object(["handle": .string("pane:1")])
            )
        )

        #expect(response.id == .number(71))
        #expect(response.error == nil)
        let renderState = try decodeResponseResult(IPCBridgeRenderStateResult.self, from: response)
        #expect(renderState.paneId == paneId)
        #expect(renderState.summary.hasReviewShell)
        #expect(renderState.summary.sidebarPosition == "right")
        #expect(renderState.diagnostics.evaluateSucceeded)
        #expect(renderState.diagnostics.pageErrorCount == 0)
        #expect(renderState.diagnostics.pageErrorKinds.isEmpty)
        #expect(renderState.diagnostics.productSession.activeProducerCount == 2)
        #expect(renderState.diagnostics.productSession.activeProducerTaskCount == 2)
        #expect(renderState.diagnostics.productSession.activeContentLeaseCount == 1)
        #expect(renderState.diagnostics.productSession.queuedFrameCount == 3)
        #expect(renderState.diagnostics.productSession.queuedByteCount == 4096)
        #expect(renderState.diagnostics.productSession.pendingFrameWaiterCount == 0)
        #expect(renderState.diagnostics.productSession.inFlightFrameReceiptCount == 1)
        #expect(renderState.diagnostics.productSession.pendingLifecycleAcknowledgementCount == 0)
        #expect(renderState.diagnostics.productSession.nextMetadataStreamSequence == 5)
    }

    @Test("debug unsafe no-auth serves Bridge telemetry snapshot method")
    func debugUnsafeNoAuthServesBridgeTelemetrySnapshotMethod() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let fixture = scoped.fixture

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(73),
                method: "bridge.telemetry.snapshot",
                params: .object(["handle": .string("pane:1")])
            )
        )

        #expect(response.id == .number(73))
        #expect(response.error == nil)
        let snapshot = try decodeResponseResult(IPCBridgeTelemetrySnapshotResult.self, from: response)
        #expect(snapshot.paneId == paneId)
        #expect(snapshot.kind == .report)
        #expect(snapshot.report?.telemetrySessionId == "telemetry-session-test")
        #expect(snapshot.report?.proofEligible == true)
        #expect(snapshot.report?.acceptedBatchSequence == 1)
        #expect(snapshot.report?.workerDiagnostics?.state == .active)
        #expect(snapshot.report?.workerDiagnostics?.mainProducer?.nextControlSequence == 3)
        #expect(snapshot.report?.workerDiagnostics?.headOutbox?.retryAttemptCount == 2)
        #expect(snapshot.report?.workerDiagnostics?.lossDiagnostics.first?.reason == .queueSaturated)
    }

    @Test("debug unsafe no-auth serves semantic Bridge control methods")
    func debugUnsafeNoAuthServesSemanticBridgeControlMethods() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let filterCorrelationId = UUIDv7.generate()
        let revealCorrelationId = UUIDv7.generate()
        let markdownCorrelationId = UUIDv7.generate()
        let scrollCorrelationId = UUIDv7.generate()
        let fixture = scoped.fixture

        let filterResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(75),
                method: "bridge.fileTree.setFilter",
                params: .object([
                    "handle": .string("pane:1"),
                    "candidate": .object([
                        "surface": .string("review"),
                        "gitStatusFilter": .string("modified"),
                        "categoryFilter": .string("source"),
                        "showBinary": .bool(true),
                        "showLarge": .bool(false),
                    ]),
                    "correlationId": .string(filterCorrelationId.uuidString),
                ])
            )
        )
        let filterResult = try decodeResponseResult(IPCBridgePageControlResult.self, from: filterResponse)
        #expect(filterResult.method == "bridge.fileTree.setFilter")
        #expect(filterResult.filterSurface == .review)
        #expect(filterResult.gitStatusFilter == .modified)
        #expect(filterResult.categoryFilter == .source)
        #expect(filterResult.showBinary)
        #expect(!filterResult.showLarge)
        #expect(filterResult.correlationId == filterCorrelationId)

        let revealResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(76),
                method: "bridge.fileTree.revealPath",
                params: .object([
                    "handle": .string("pane:1"),
                    "path": .string("Sources/App/View.swift"),
                    "correlationId": .string(revealCorrelationId.uuidString),
                ])
            )
        )
        let revealResult = try decodeResponseResult(IPCBridgePageControlResult.self, from: revealResponse)
        #expect(revealResult.method == "bridge.fileTree.revealPath")
        #expect(revealResult.itemId == "item-source")
        #expect(revealResult.path == "Sources/App/View.swift")
        #expect(revealResult.correlationId == revealCorrelationId)

        let markdownResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(77),
                method: "bridge.fileView.showMarkdownPreview",
                params: .object([
                    "handle": .string("pane:1"),
                    "itemId": .string("item-source"),
                    "correlationId": .string(markdownCorrelationId.uuidString),
                ])
            )
        )
        let markdownResult = try decodeResponseResult(IPCBridgePageControlResult.self, from: markdownResponse)
        #expect(markdownResult.method == "bridge.fileView.showMarkdownPreview")
        #expect(markdownResult.itemId == "item-source")
        #expect(markdownResult.renderMode == "markdownPreview")
        #expect(markdownResult.correlationId == markdownCorrelationId)

        let scrollResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(78),
                method: "bridge.diff.scrollToFile",
                params: .object([
                    "handle": .string("pane:1"),
                    "itemId": .string("item-source"),
                    "correlationId": .string(scrollCorrelationId.uuidString),
                ])
            )
        )
        let scrollResult = try decodeResponseResult(IPCBridgePageControlResult.self, from: scrollResponse)
        #expect(scrollResult.method == "bridge.diff.scrollToFile")
        #expect(scrollResult.itemId == "item-source")
        #expect(scrollResult.correlationId == scrollCorrelationId)
    }

    @Test("debug unsafe no-auth preserves the Files filter candidate")
    func debugUnsafeNoAuthPreservesFilesFilterCandidate() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let correlationId = UUIDv7.generate()
        let fixture = scoped.fixture

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(91),
                method: "bridge.fileTree.setFilter",
                params: .object([
                    "handle": .string("pane:1"),
                    "candidate": .object([
                        "surface": .string("files"),
                        "categoryFilter": .string("docs"),
                    ]),
                    "correlationId": .string(correlationId.uuidString),
                ])
            )
        )

        let result = try decodeResponseResult(IPCBridgePageControlResult.self, from: response)
        #expect(result.filterSurface == .files)
        #expect(result.gitStatusFilter == .all)
        #expect(result.categoryFilter == .docs)
        #expect(!result.showBinary)
        #expect(!result.showLarge)
        #expect(result.correlationId == correlationId)
    }

    @Test("debug unsafe no-auth serves Bridge diff expand and collapse methods")
    func debugUnsafeNoAuthServesBridgeDiffExpandAndCollapseMethods() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let collapseCorrelationId = UUIDv7.generate()
        let expandCorrelationId = UUIDv7.generate()
        let fixture = scoped.fixture

        let collapseResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(79),
                method: "bridge.diff.collapseFile",
                params: .object([
                    "handle": .string("pane:1"),
                    "itemId": .string("item-source"),
                    "correlationId": .string(collapseCorrelationId.uuidString),
                ])
            )
        )
        let collapseResult = try decodeResponseResult(IPCBridgePageControlResult.self, from: collapseResponse)
        #expect(collapseResult.method == "bridge.diff.collapseFile")
        #expect(collapseResult.itemId == "item-source")
        #expect(collapseResult.correlationId == collapseCorrelationId)

        let expandResponse = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(80),
                method: "bridge.diff.expandFile",
                params: .object([
                    "handle": .string("pane:1"),
                    "itemId": .string("item-source"),
                    "correlationId": .string(expandCorrelationId.uuidString),
                ])
            )
        )
        let expandResult = try decodeResponseResult(IPCBridgePageControlResult.self, from: expandResponse)
        #expect(expandResult.method == "bridge.diff.expandFile")
        #expect(expandResult.itemId == "item-source")
        #expect(expandResult.paneId == paneId)
        #expect(expandResult.correlationId == expandCorrelationId)
    }

}

@Suite("AgentStudioIPCBridgeRenderDiagnosticsTests", .serialized)
struct AgentStudioIPCBridgeRenderDiagnosticsTests {
    @Test("Bridge render state preserves bounded native activity diagnostics through JSON-RPC")
    func bridgeRenderStatePreservesBoundedNativeActivityDiagnosticsThroughJSONRPC() throws {
        let paneId = UUID()
        let fixtureResult = try JSONDecoder().decode(
            IPCBridgeRenderStateResult.self,
            from: Data(
                """
                {
                  "paneId": "\(paneId.uuidString)",
                  "summary": {
                    "pageTitle": "AgentStudio Bridge",
                    "hasAppRoot": true,
                    "hasEmptyShell": false,
                    "hasReviewShell": true
                  },
                  "diagnostics": {
                    "evaluateSucceeded": true,
                    "pageErrorCount": 0,
                    "pageErrorKinds": [],
                    "pageErrorMessages": [],
                    "nativeActivity": "loadedHidden",
                    "foregroundWorkEpoch": 7,
                    "dirtyFactPresent": true,
                    "activeRefreshPassPresent": false,
                    "refreshPassCount": 3,
                    "productSession": {
                      "activeProducerCount": 0,
                      "activeProducerTaskCount": 0,
                      "activeContentLeaseCount": 0,
                      "queuedFrameCount": 0,
                      "queuedByteCount": 0,
                      "pendingFrameWaiterCount": 0,
                      "inFlightFrameReceiptCount": 0,
                      "pendingLifecycleAcknowledgementCount": 0,
                      "nextMetadataStreamSequence": 0
                    }
                  }
                }
                """.utf8
            )
        )
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)],
            bridgePort: FakeBridgePort(paneId: paneId, renderStateResult: fixtureResult)
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(72),
                method: "bridge.diff.renderState",
                params: .object(["handle": .string("pane:1")])
            )
        )

        #expect(response.id == .number(72))
        #expect(response.error == nil)
        guard case .object(let result)? = response.result,
            case .object(let diagnostics)? = result["diagnostics"]
        else {
            Issue.record("expected Bridge render-state diagnostics object")
            return
        }
        #expect(diagnostics["nativeActivity"] == .string("loadedHidden"))
        #expect(diagnostics["foregroundWorkEpoch"] == .number(7))
        #expect(diagnostics["dirtyFactPresent"] == .bool(true))
        #expect(diagnostics["activeRefreshPassPresent"] == .bool(false))
        #expect(diagnostics["refreshPassCount"] == .number(3))
    }

}

@Suite("AgentStudioIPCBridgeSearchModeTests", .serialized)
struct AgentStudioIPCBridgeSearchModeTests {
    @Test("debug unsafe no-auth preserves semantic Bridge Search mode")
    func debugUnsafeNoAuthPreservesSemanticBridgeSearchMode() throws {
        let paneId = UUIDv7.generate()
        let correlationId = UUIDv7.generate()
        let searchModeInvocationRecorder = BridgeSearchModeInvocationRecorder()
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)],
            bridgePort: FakeBridgePort(
                paneId: paneId,
                searchModeInvocationRecorder: searchModeInvocationRecorder
            )
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(74),
                method: "bridge.fileTree.search",
                params: .object([
                    "handle": .string("pane:1"),
                    "searchText": .string("BridgePaneController"),
                    "searchMode": .object(["kind": .string("regex")]),
                    "correlationId": .string(correlationId.uuidString),
                ])
            )
        )

        let result = try decodeResponseResult(IPCBridgePageControlResult.self, from: response)
        #expect(result.paneId == paneId)
        #expect(result.method == "bridge.fileTree.search")
        #expect(result.status == "accepted")
        #expect(result.treeSearchText == "BridgePaneController")
        #expect(searchModeInvocationRecorder.snapshot() == [.regex])
        #expect(result.correlationId == correlationId)
    }

}

@Suite(
    "AgentStudioIPCBridgeNonBridgeTargetTests", .serialized,
    BridgeLiveServerFixtureTrait(configuration: .unsafeTerminal))
struct AgentStudioIPCBridgeNonBridgeTargetTests {
    @Test("Bridge methods reject valid non-Bridge pane targets as unsupported")
    func bridgeMethodsRejectValidNonBridgePaneTargetsAsUnsupported() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let fixture = scoped.fixture

        for bridgeRequest in nonBridgeTargetRequests() {
            let response = try sendRequest(
                socketPath: fixture.paths.socketURL.path,
                request: JSONRPCClientRequest(
                    id: .number(bridgeRequest.id),
                    method: bridgeRequest.method,
                    params: bridgeRequest.params
                )
            )

            #expect(response.id == .number(bridgeRequest.id))
            #expect(response.error?.code == -32_003)
            #expect(response.error?.message == "unsupported target")
            #expect(response.result == nil)
        }
    }

    @Test("Bridge expand and collapse methods reject valid non-Bridge pane targets as unsupported")
    func bridgeExpandAndCollapseMethodsRejectValidNonBridgePaneTargetsAsUnsupported() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let fixture = scoped.fixture

        let bridgeRequests: [(id: Int, method: String)] = [
            (91, "bridge.diff.expandFile"),
            (92, "bridge.diff.collapseFile"),
        ]

        for bridgeRequest in bridgeRequests {
            let response = try sendRequest(
                socketPath: fixture.paths.socketURL.path,
                request: JSONRPCClientRequest(
                    id: .number(bridgeRequest.id),
                    method: bridgeRequest.method,
                    params: .object([
                        "handle": .string("pane:1"),
                        "itemId": .string("item-source"),
                        "correlationId": .string(UUIDv7.generate().uuidString),
                    ])
                )
            )

            #expect(response.id == .number(bridgeRequest.id))
            #expect(response.error?.code == -32_003)
            #expect(response.error?.message == "unsupported target")
            #expect(response.result == nil)
        }
    }

}

@Suite("AgentStudioIPCBridgeDiagnosticTargetTests", .serialized)
struct AgentStudioIPCBridgeDiagnosticTargetTests {
    @Test("diagnostic Bridge reads reject non-Bridge pane targets")
    func diagnosticBridgeReadsRejectNonBridgePaneTargets() throws {
        let paneId = UUID()
        let fixture = try LiveServerFixture(
            panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .terminal)]
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()
        let token = fixture.installDebugCredential()
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var frameReader = TestFrameReader()
        try login(connection: connection, token: token, requestId: 91, reader: &frameReader)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(92),
                method: "bridge.diff.getPackage",
                params: .object(["handle": .string("pane:1")])
            )
        )

        let response = try frameReader.receiveResponse(connection: connection)
        #expect(response.error?.code == -32_003)
        #expect(response.error?.message == "unsupported target")
        #expect(response.result == nil)
    }

}

@Suite("AgentStudioIPCBridgePaneAgentTests", .serialized, BridgeLiveServerFixtureTrait(configuration: .safeBridge))
struct AgentStudioIPCBridgePaneAgentTests {
    @Test("pane principals hear that the Bridge open method is not yet allowed")
    func panePrincipalsCannotDiscoverDebugOnlyBridgeOpenMethod() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let fixture = scoped.fixture
        let token = try fixture.issueTestCredential(
            for: .pane(paneId: paneId, credentialRecordId: UUIDv7.generate(), status: .registered)
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var frameReader = TestFrameReader()
        try login(connection: connection, token: token, requestId: 71, reader: &frameReader)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(72),
                method: "bridge.diff.load",
                params: .object([
                    "target": .string("pane:active")
                ])
            )
        )

        let response = try frameReader.receiveResponse(connection: connection)
        #expect(response.error?.code == -32_011)
        #expect(
            response.error?.data
                == .object(["reason": .string("notYetAllowed"), "name": .string("bridge.diff.load")]))
        #expect(response.result == nil)
    }

    @Test("Bridge select publishes notification for a diagnostic subscriber")
    func bridgeSelectPublishesNotificationForDiagnosticSubscriber() throws {
        let scoped = try #require(BridgeLiveServerFixtureContext.current)
        let paneId = scoped.paneId
        let correlationId = UUIDv7.generate()
        let fixture = scoped.fixture
        let token = fixture.installDebugCredential()
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var frameReader = TestFrameReader()
        let subscriptionCorrelationId = UUIDv7.generate()

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(68),
                method: "auth.login",
                params: .object(["token": .string(token.rawValue)])
            )
        )
        _ = try frameReader.receiveResponse(connection: connection)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(69),
                method: "events.subscribe",
                params: .object([
                    "eventNames": .array([.string(IPCEventName.bridgeFileSelected.rawValue)]),
                    "correlationId": .string(subscriptionCorrelationId.uuidString),
                ])
            )
        )
        let subscriptionResponse = try frameReader.receiveResponse(connection: connection)
        try #require(subscriptionResponse.error == nil)
        let subscription = try decodeResponseResult(IPCEventSubscriptionResult.self, from: subscriptionResponse)
        #expect(subscription.eventNames == [.bridgeFileSelected])

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(70),
                method: "bridge.diff.selectFile",
                params: .object([
                    "handle": .string("pane:1"),
                    "itemId": .string("item-source"),
                    "correlationId": .string(correlationId.uuidString),
                ])
            )
        )

        func validateSelectionResponse(_ response: JSONRPCResponseMessage) throws {
            #expect(response.id == .number(70))
            #expect(response.error == nil)
            let result = try decodeResponseResult(IPCBridgeReviewSelectFileResult.self, from: response)
            #expect(result.paneId == paneId)
            #expect(result.itemId == "item-source")
            #expect(result.selected)
            #expect(result.correlationId == correlationId)
        }

        let firstFrame = try frameReader.receiveFrame(connection: connection)
        let response: JSONRPCResponseMessage
        let notificationFrame: String
        if firstFrame.contains("events.notification") {
            notificationFrame = firstFrame
            response = try frameReader.receiveResponse(connection: connection)
            try validateSelectionResponse(response)
        } else {
            response = try JSONRPCCodec.decodeResponse(firstFrame)
            try validateSelectionResponse(response)
            notificationFrame = try frameReader.receiveFrame(connection: connection)
        }

        let notificationObject = try #require(
            try JSONSerialization.jsonObject(with: Data(notificationFrame.utf8)) as? [String: Any]
        )
        let params = try #require(notificationObject["params"] as? [String: Any])
        let payload = try #require(params["payload"] as? [String: Any])
        let bridgePayload = try #require(payload["bridge"] as? [String: Any])

        #expect(params["name"] as? String == IPCEventName.bridgeFileSelected.rawValue)
        #expect(bridgePayload["paneId"] as? String == paneId.uuidString)
        #expect(bridgePayload["itemId"] as? String == "item-source")
    }
}

private func nonBridgeTargetRequests() -> [(id: Int, method: String, params: JSONValue)] {
    nonBridgeReadTargetRequests() + nonBridgeMutationTargetRequests()
}

private func nonBridgeReadTargetRequests() -> [(id: Int, method: String, params: JSONValue)] {
    [
        (79, "bridge.diff.getPackage", .object(["handle": .string("pane:1")])),
        (80, "bridge.diff.renderState", .object(["handle": .string("pane:1")])),
        (
            88,
            "bridge.fileView.getContent",
            .object([
                "handle": .string("pane:1"),
                "contentHandleId": .string("content-head"),
                "reviewGeneration": .number(1),
            ])
        ),
        (89, "bridge.telemetry.snapshot", .object(["handle": .string("pane:1")])),
    ]
}

private func nonBridgeMutationTargetRequests() -> [(id: Int, method: String, params: JSONValue)] {
    [
        (
            81,
            "bridge.diff.refresh",
            .object([
                "handle": .string("pane:1"),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        ),
        (
            82,
            "bridge.diff.selectFile",
            .object([
                "handle": .string("pane:1"),
                "itemId": .string("item-source"),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        ),
        (
            83,
            "bridge.diff.scrollToFile",
            .object([
                "handle": .string("pane:1"),
                "itemId": .string("item-source"),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        ),
        (
            84,
            "bridge.fileTree.search",
            .object([
                "handle": .string("pane:1"),
                "searchText": .string("BridgePaneController"),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        ),
        (85, "bridge.fileTree.setFilter", bridgeReviewFilterParams(handle: "pane:1", correlationId: UUIDv7.generate())),
        (
            86,
            "bridge.fileTree.revealPath",
            .object([
                "handle": .string("pane:1"),
                "path": .string("Sources/App/View.swift"),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        ),
        (
            87,
            "bridge.fileView.showMarkdownPreview",
            .object([
                "handle": .string("pane:1"),
                "itemId": .string("item-source"),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        ),
        (
            90,
            "bridge.telemetry.flush",
            .object([
                "handle": .string("pane:1"),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        ),
    ]
}

private func bridgeReviewFilterParams(handle: String, correlationId: UUID) -> JSONValue {
    .object([
        "handle": .string(handle),
        "candidate": .object([
            "surface": .string("review"),
            "gitStatusFilter": .string("modified"),
            "categoryFilter": .string("source"),
            "showBinary": .bool(false),
            "showLarge": .bool(false),
        ]),
        "correlationId": .string(correlationId.uuidString),
    ])
}

@Suite("AgentStudioIPCBridgeRejectedControlTests", .serialized)
struct AgentStudioIPCBridgeRejectedControlTests {
    @Test("rejected Bridge page-control commands do not publish file selection notifications")
    func rejectedBridgePageControlCommandsDoNotPublishFileSelectionNotifications() throws {
        let paneId = UUID()
        let fixture = try LiveServerFixture(
            panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)],
            bridgePort: FakeBridgePort(
                paneId: paneId,
                pageControlStatus: "rejected",
                pageControlReason: "missing_item"
            )
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()
        let token = fixture.installDebugCredential()
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var frameReader = TestFrameReader()
        try login(connection: connection, token: token, requestId: 93, reader: &frameReader)
        let subscriptionCorrelationId = UUIDv7.generate()
        let correlationId = UUIDv7.generate()

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(94),
                method: "events.subscribe",
                params: .object([
                    "eventNames": .array([.string(IPCEventName.bridgeFileSelected.rawValue)]),
                    "correlationId": .string(subscriptionCorrelationId.uuidString),
                ])
            )
        )
        let subscriptionResponse = try frameReader.receiveResponse(connection: connection)
        try #require(subscriptionResponse.error == nil)
        let subscription = try decodeResponseResult(IPCEventSubscriptionResult.self, from: subscriptionResponse)
        #expect(subscription.eventNames == [.bridgeFileSelected])

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(95),
                method: "bridge.diff.scrollToFile",
                params: .object([
                    "handle": .string("pane:1"),
                    "itemId": .string("missing-item"),
                    "correlationId": .string(correlationId.uuidString),
                ])
            )
        )

        let response = try frameReader.receiveResponse(connection: connection)
        let result = try decodeResponseResult(IPCBridgePageControlResult.self, from: response)
        #expect(result.status == "rejected")
        #expect(result.reason == "missing_item")
        #expect(result.correlationId == correlationId)
        #expect(!frameReader.hasBufferedFrame(containing: "events.notification"))
    }

}
