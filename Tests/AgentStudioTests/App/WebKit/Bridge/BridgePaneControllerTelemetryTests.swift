import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgePaneControllerTelemetryTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("loadDiff records correlated Swift review telemetry")
        func loadDiff_records_correlated_swift_review_telemetry() async throws {
            let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let changedFile = makeBridgeEndpointChangedFile(
                fileId: "source",
                path: "Sources/App/View.swift",
                sizeBytes: 100
            )
            let comparison = BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: comparison,
                contentByHandleId: [:],
                contributionCapture: BridgeContributionComparisonCapture(
                    resolvedTargetOID: "resolved-head-minus-one",
                    reviewedHeadOID: "reviewed-head",
                    baseRole: .commonCommit,
                    baseOID: "base-head-minus-one",
                    comparison: comparison
                )
            )
            let recorder = BridgeTelemetryRecorderSpy()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .ref(name: "HEAD~1"))
                ),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: provider,
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: [.swift, .webKit]),
                telemetryRecorder: recorder,
                traceContextFactory: BridgeTraceContextFactory(
                    makeTraceId: { "11111111111111111111111111111111" },
                    makeSpanId: { "2222222222222222" }
                ),
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let commandId = UUID()

            try await showReviewInNativeFixture(controller)

            let result = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(diffId: UUIDv7.generate(), worktreeId: headEndpoint.worktreeId, patchData: Data())
                ),
                commandId: commandId,
                correlationId: nil
            )

            #expect(result == .success(commandId: commandId))
            let samples = await recorder.samples()
            let packageBuild = try #require(
                samples.first { $0.name == "performance.bridge.swift.package_build" }
            )
            let deltaBuild = try #require(
                samples.first { $0.name == "performance.bridge.swift.delta_build" }
            )
            let contentRegister = try #require(
                samples.first { $0.name == "performance.bridge.swift.content_register" }
            )
            #expect(packageBuild.traceContext?.traceId == "11111111111111111111111111111111")
            #expect(packageBuild.traceContext?.parentSpanId == nil)
            #expect(deltaBuild.traceContext?.parentSpanId == packageBuild.traceContext?.spanId)
            #expect(contentRegister.traceContext?.parentSpanId == packageBuild.traceContext?.spanId)
            #expect(packageBuild.stringAttributes["agentstudio.bridge.phase"] == "package_build")
            #expect(packageBuild.stringAttributes["agentstudio.bridge.plane"] == "data")
            #expect(packageBuild.stringAttributes["agentstudio.bridge.priority"] == "cold")
            #expect(packageBuild.stringAttributes["agentstudio.bridge.slice"] == "review_metadata")
            #expect(deltaBuild.stringAttributes["agentstudio.bridge.phase"] == "delta_build")
            #expect(deltaBuild.stringAttributes["agentstudio.bridge.plane"] == "data")
            #expect(deltaBuild.stringAttributes["agentstudio.bridge.priority"] == "warm")
            #expect(deltaBuild.stringAttributes["agentstudio.bridge.slice"] == "review_delta")
            #expect(contentRegister.stringAttributes["agentstudio.bridge.phase"] == "content_register")
            #expect(contentRegister.stringAttributes["agentstudio.bridge.plane"] == "data")
            #expect(contentRegister.stringAttributes["agentstudio.bridge.priority"] == "cold")
            #expect(contentRegister.stringAttributes["agentstudio.bridge.slice"] == "review_metadata")
        }

        @Test("release-style telemetry policy disables bridge telemetry wiring")
        func releaseStyleTelemetryPolicyDisablesBridgeTelemetryWiring() async {
            let recorder = BridgeTelemetryRecorderSpy()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .ref(name: "HEAD~1"))
                ),
                appRootURL: testBridgeAppRootURL(),
                telemetryRuntimePolicy: BridgeTelemetryRuntimePolicy(isDebugBuild: false),
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: [.swift, .web, .webKit]),
                telemetryRecorder: recorder,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            await controller.recordSwiftTelemetry(
                name: "performance.bridge.swift.package_build",
                phase: "package_build",
                priorityHint: .warm,
                traceContext: nil,
                durationMilliseconds: 1
            )
            let flushResult = try? await controller.flushTelemetryForIPC()

            #expect(controller.telemetrySessionOwner == nil)
            #expect(flushResult?.kind == .unavailable)
            #expect(flushResult?.unavailableReason == .disabled)
            #expect(await recorder.samples().isEmpty)
        }

        @Test("IPC telemetry flush reports disabled without recorder fallback")
        func ipcTelemetryFlushReportsDisabledWithoutRecorderFallback() async throws {
            let recorder = BridgeTelemetryRecorderSpy()
            await recorder.setDrainFailure()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                telemetryRecorder: recorder,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await controller.flushTelemetryForIPC()

            #expect(result.kind == .unavailable)
            #expect(result.unavailableReason == .disabled)
            #expect(result.report == nil)
        }
    }
}

private actor BridgeTelemetryRecorderSpy: BridgePerformanceTraceRecording {
    enum Failure: Error {
        case drainFailed
    }

    private var recordedSamples: [BridgeTelemetrySample] = []
    private var recordedDrops: [BridgeTelemetryDropReason] = []
    private var shouldFailDrain = false

    func record(sample: BridgeTelemetrySample, receivedAtUnixNano: UInt64) async {
        recordedSamples.append(sample)
    }

    func recordDrop(
        reason: BridgeTelemetryDropReason,
        droppedCount: Int,
        firstRejectedEventName: String?,
        receivedAtUnixNano: UInt64
    ) async {
        _ = firstRejectedEventName
        recordedDrops.append(reason)
    }

    func samples() -> [BridgeTelemetrySample] {
        recordedSamples
    }

    func setDrainFailure() {
        shouldFailDrain = true
    }

    func drain() async throws {
        if shouldFailDrain {
            throw Failure.drainFailed
        }
    }
}
