import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioTraceConfigurationTests {
    @Test
    func missingTagsDisablesTracing() {
        let configuration = AgentStudioTraceConfiguration.from(
            environment: [:],
            releaseChannel: .stable,
            isDebugBuild: false
        )

        #expect(!configuration.isEnabled)
        #expect(configuration.enabledTags.isEmpty)
    }

    @Test
    func offTagsDisableTracing() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_TAGS": "off"
        ])

        #expect(!configuration.isEnabled)
    }

    @Test
    func commaSeparatedTagsEnableSelectedTags() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_TAGS": "eventbus, runtime"
        ])

        #expect(configuration.isEnabled(.eventbus))
        #expect(configuration.isEnabled(.runtime))
        #expect(!configuration.isEnabled(.atoms))
    }

    @Test
    func notificationObservabilityConsumerTagsParseFromSmokeSelector() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_TAGS":
                "app.focus,runtime,eventbus,terminal.activity,terminal.signal,inbox,ui.surface,ui.interaction,paneInbox"
        ])

        #expect(configuration.unknownTagSelectors.isEmpty)
        #expect(configuration.isEnabled(.appFocus))
        #expect(configuration.isEnabled(.runtime))
        #expect(configuration.isEnabled(.eventbus))
        #expect(configuration.isEnabled(.terminalActivity))
        #expect(configuration.isEnabled(.terminalSignal))
        #expect(configuration.isEnabled(.inbox))
        #expect(configuration.isEnabled(.uiSurface))
        #expect(configuration.isEnabled(.uiInteraction))
        #expect(configuration.isEnabled(.paneInbox))
    }

    @Test
    func wildcardEnablesAllTagsExceptHighVolumeAtoms() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_TAGS": "*"
        ])

        #expect(configuration.enabledTags == Set(AgentStudioTraceTag.allCases).subtracting([.atoms]))
        #expect(!configuration.isEnabled(.atoms))
    }

    @Test
    func atomsRequiresExplicitSelectionAlongsideWildcard() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_TAGS": "*,atoms"
        ])

        #expect(configuration.enabledTags == Set(AgentStudioTraceTag.allCases))
        #expect(configuration.isEnabled(.atoms))
    }

    @Test
    func tagSelectionTreatsNilEmptyAndOffAsDisabled() {
        #expect(AgentStudioTraceTag.parseSelection(nil).tags.isEmpty)
        #expect(AgentStudioTraceTag.parseSelection("").tags.isEmpty)
        #expect(AgentStudioTraceTag.parseSelection("  off  ").tags.isEmpty)
        #expect(AgentStudioTraceTag.parseSelection(nil).unknownSelectors.isEmpty)
        #expect(AgentStudioTraceTag.parseSelection("").unknownSelectors.isEmpty)
        #expect(AgentStudioTraceTag.parseSelection("  off  ").unknownSelectors.isEmpty)
    }

    @Test
    func tagSelectionSupportsPrefixWildcards() {
        let selection = AgentStudioTraceTag.parseSelection("terminal.*")

        #expect(selection.tags == [.terminalActivity, .terminalSignal, .terminalStartup, .terminalTCC])
        #expect(selection.unknownSelectors.isEmpty)
    }

    @Test
    func terminalTCCTraceTagParsesAsExplicitOptInLane() {
        let selection = AgentStudioTraceTag.parseSelection("terminal.tcc")

        #expect(selection.tags == [.terminalTCC])
        #expect(selection.unknownSelectors.isEmpty)
        #expect(!AgentStudioTraceConfiguration.safeDefaultTags.contains(.terminalTCC))
    }

    @Test
    func terminalSignalTraceTagParsesAsExplicitOptInLane() {
        let selection = AgentStudioTraceTag.parseSelection("terminal.signal")

        #expect(selection.tags == [.terminalSignal])
        #expect(selection.unknownSelectors.isEmpty)
        #expect(!AgentStudioTraceConfiguration.safeDefaultTags.contains(.terminalSignal))
    }

    @Test
    func startupTraceTagsParseAsAppAndTerminalLanes() {
        let appSelection = AgentStudioTraceTag.parseSelection("app.*")
        let terminalSelection = AgentStudioTraceTag.parseSelection("terminal.*")

        #expect(appSelection.tags.contains(.appStartup))
        #expect(appSelection.tags.contains(.appFocus))
        #expect(terminalSelection.tags.contains(.terminalStartup))
        #expect(terminalSelection.tags.contains(.terminalActivity))
        #expect(terminalSelection.tags.contains(.terminalSignal))
        #expect(terminalSelection.tags.contains(.terminalTCC))
        #expect(!terminalSelection.tags.contains(.persistenceOperation))
        #expect(appSelection.unknownSelectors.isEmpty)
        #expect(terminalSelection.unknownSelectors.isEmpty)
    }

    @Test
    func startupTraceTagsParseFromExplicitSmokeSelector() {
        let selection = AgentStudioTraceTag.parseSelection("app.startup,terminal.startup,persistence.*")

        #expect(
            selection.tags == [
                .appStartup,
                .terminalStartup,
                .persistenceOperation,
                .persistenceRecovery,
                .persistenceSnapshot,
            ])
        #expect(selection.unknownSelectors.isEmpty)
    }

    @Test
    func persistenceTraceTagsParseAsOperationAndRecoverySiblings() {
        let exactSelection = AgentStudioTraceTag.parseSelection(
            "persistence.operation,persistence.recovery,persistence.snapshot"
        )
        let wildcardSelection = AgentStudioTraceTag.parseSelection("persistence.*")

        #expect(exactSelection.tags == [.persistenceOperation, .persistenceRecovery, .persistenceSnapshot])
        #expect(exactSelection.unknownSelectors.isEmpty)
        #expect(wildcardSelection.tags == [.persistenceOperation, .persistenceRecovery, .persistenceSnapshot])
        #expect(wildcardSelection.unknownSelectors.isEmpty)
    }

    @Test
    func performanceTraceTagParsesAsExplicitOptInLane() {
        let selection = AgentStudioTraceTag.parseSelection("performance")

        #expect(selection.tags == [.performance])
        #expect(selection.unknownSelectors.isEmpty)
        #expect(!AgentStudioTraceConfiguration.safeDefaultTags.contains(.performance))
    }

    @Test
    func bridgePerformanceTraceTagsParseAsExplicitOptInLanes() {
        let selection = AgentStudioTraceTag.parseSelection("bridge.performance.*")

        #expect(selection.unknownSelectors.isEmpty)
        #expect(selection.tags.contains(.bridgePerformanceSwift))
        #expect(selection.tags.contains(.bridgePerformanceWeb))
        #expect(selection.tags.contains(.bridgePerformanceWebKit))
        #expect(!AgentStudioTraceConfiguration.safeDefaultTags.contains(.bridgePerformanceSwift))
        #expect(!AgentStudioTraceConfiguration.safeDefaultTags.contains(.bridgePerformanceWeb))
        #expect(!AgentStudioTraceConfiguration.safeDefaultTags.contains(.bridgePerformanceWebKit))
    }

    @Test
    func explicitWildcardCanEnableBridgePerformanceTagsForProofRuns() {
        let selection = AgentStudioTraceTag.parseSelection("*")

        #expect(selection.unknownSelectors.isEmpty)
        #expect(selection.tags.contains(.bridgePerformanceSwift))
        #expect(selection.tags.contains(.bridgePerformanceWeb))
        #expect(selection.tags.contains(.bridgePerformanceWebKit))
    }

    @Test
    func tagSelectionKeepsMixedKnownAndUnknownSelectors() {
        let selection = AgentStudioTraceTag.parseSelection(" Runtime, paneInbox, missing.tag ")

        #expect(selection.tags == [.runtime, .paneInbox])
        #expect(selection.unknownSelectors == ["missing.tag"])
    }

    @Test
    func traceNameAndDirectoryAreSanitizedForFileOutput() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
            "AGENTSTUDIO_TRACE_NAME": "Drawer Target Smoke!",
            "AGENTSTUDIO_TRACE_DIR": "/tmp/agent studio traces",
        ])

        #expect(configuration.traceName == "Drawer-Target-Smoke")
        #expect(
            configuration.outputFileURL(processIdentifier: 42).path
                == "/tmp/agent studio traces/agentstudio-Drawer-Target-Smoke-42.jsonl")
    }

    @Test
    func immediateFlushModeIsOptIn() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_FLUSH": "immediate",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
        ])

        #expect(configuration.flushMode == .immediate)
    }

    @Test
    func jsonlBackendIsStableDefaultWhenTagsAreExplicit() {
        let configuration = AgentStudioTraceConfiguration.from(
            environment: [
                "AGENTSTUDIO_TRACE_TAGS": "runtime"
            ],
            releaseChannel: .stable,
            isDebugBuild: false
        )

        #expect(configuration.backend == .jsonl)
        #expect(configuration.runtimeFlavor == .stable)
        #expect(configuration.otlpEndpoint == nil)
    }

    @Test
    func debugBuildUsesSafeBaselineAndBothBackendWhenTagsAreMissing() {
        let configuration = AgentStudioTraceConfiguration.from(
            environment: [:],
            releaseChannel: .beta,
            isDebugBuild: true
        )

        #expect(configuration.backend == .both)
        #expect(configuration.runtimeFlavor == .debug)
        #expect(configuration.enabledTags == AgentStudioTraceConfiguration.safeDefaultTags)
        #expect(configuration.otlpEndpoint?.absoluteString == "http://127.0.0.1:4318")
        #expect(configuration.otlpProtocol == .httpProtobuf)
    }

    @Test
    func betaBuildUsesSafeBaselineAndBothBackendWhenTagsAreMissing() {
        let configuration = AgentStudioTraceConfiguration.from(
            environment: [:],
            releaseChannel: .beta,
            isDebugBuild: false
        )

        #expect(configuration.backend == .both)
        #expect(configuration.runtimeFlavor == .beta)
        #expect(configuration.enabledTags == AgentStudioTraceConfiguration.safeDefaultTags)
    }

    @Test
    func offTagsDisableDebugAndBetaBaseline() {
        let debugConfiguration = AgentStudioTraceConfiguration.from(
            environment: [
                "AGENTSTUDIO_TRACE_TAGS": "off"
            ],
            releaseChannel: .stable,
            isDebugBuild: true
        )
        let betaConfiguration = AgentStudioTraceConfiguration.from(
            environment: [
                "AGENTSTUDIO_TRACE_TAGS": "off"
            ],
            releaseChannel: .beta,
            isDebugBuild: false
        )

        #expect(!debugConfiguration.isEnabled)
        #expect(!betaConfiguration.isEnabled)
        #expect(debugConfiguration.backend == .jsonl)
        #expect(betaConfiguration.backend == .jsonl)
        #expect(debugConfiguration.otlpEndpoint == nil)
        #expect(betaConfiguration.otlpEndpoint == nil)
    }

    @Test
    func backendSelectionSupportsJsonlOtlpBothAndUnknownFallback() {
        let explicitConfiguration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
        ])
        let otlpConfiguration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "otlp",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
        ])
        let bothConfiguration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "both",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
        ])
        let unknownConfiguration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "otpl",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
        ])

        #expect(explicitConfiguration.backend == .jsonl)
        #expect(explicitConfiguration.unsupportedBackendSelector == nil)
        #expect(otlpConfiguration.backend == .otlp)
        #expect(otlpConfiguration.unsupportedBackendSelector == nil)
        #expect(bothConfiguration.backend == .both)
        #expect(bothConfiguration.unsupportedBackendSelector == nil)
        #expect(unknownConfiguration.backend == .jsonl)
        #expect(unknownConfiguration.unsupportedBackendSelector == "otpl")
    }

    @Test
    func otlpEndpointPolicyAcceptsOnlyLoopbackHttpProtobuf() {
        let loopbackConfiguration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "otlp",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
        ])
        let remoteConfiguration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "both",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example.com:4318",
        ])
        let grpcConfiguration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "otlp",
            "AGENTSTUDIO_TRACE_TAGS": "runtime",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
        ])

        #expect(loopbackConfiguration.backend == .otlp)
        #expect(loopbackConfiguration.otlpEndpoint?.absoluteString == "http://localhost:4318")
        #expect(loopbackConfiguration.otlpProtocol == .httpProtobuf)
        #expect(remoteConfiguration.backend == .jsonl)
        #expect(remoteConfiguration.rejectedOTLPEndpointSelector == "https://collector.example.com:4318")
        #expect(remoteConfiguration.otlpEndpoint == nil)
        #expect(grpcConfiguration.backend == .jsonl)
        #expect(grpcConfiguration.unsupportedOTLPProtocolSelector == "grpc")
    }

    @Test
    func perSignalRemoteEndpointRefusesAllOTLP() {
        // Spec R2: the SDK reads these after the app supplies its shared endpoint.
        for signal in ["LOGS", "METRICS", "TRACES"] {
            let remoteEndpoint = "http://collector.example.com:4318/v1/\(signal.lowercased())"
            let configuration = AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "both",
                "AGENTSTUDIO_TRACE_TAGS": "runtime",
                "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318",
                "OTEL_EXPORTER_OTLP_\(signal)_ENDPOINT": remoteEndpoint,
            ])

            #expect(configuration.backend == .jsonl, "\(signal) must refuse OTLP and preserve JSONL")
            #expect(configuration.otlpEndpoint == nil)
            #expect(configuration.rejectedOTLPEndpointSelector == remoteEndpoint)
        }
    }

    @Test
    func perSignalLoopbackEndpointsKeepOTLPEnabled() {
        for signal in ["LOGS", "METRICS", "TRACES"] {
            for host in ["localhost", "127.0.0.1", "[::1]"] {
                let configuration = AgentStudioTraceConfiguration.from(environment: [
                    "AGENTSTUDIO_TRACE_BACKEND": "both",
                    "AGENTSTUDIO_TRACE_TAGS": "runtime",
                    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318",
                    "OTEL_EXPORTER_OTLP_\(signal)_ENDPOINT": "http://\(host):4319/v1/\(signal.lowercased())",
                ])

                #expect(configuration.backend == .both)
                #expect(configuration.otlpEndpoint?.absoluteString == "http://127.0.0.1:4318")
                #expect(configuration.rejectedOTLPEndpointSelector == nil)
            }
        }
    }

    @Test
    func unknownTagSelectorsAreReportedWithoutEnablingTracing() {
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_TAGS": "runtmie"
        ])

        #expect(!configuration.isEnabled)
        #expect(configuration.unknownTagSelectors == ["runtmie"])
    }
}
