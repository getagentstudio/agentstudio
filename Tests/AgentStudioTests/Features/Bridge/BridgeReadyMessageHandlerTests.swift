import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite(.serialized)
final class BridgeReadyMessageHandlerTests {
    @Test
    func acceptsPaneReloadBeforeProductSessionBootstrap() {
        let json =
            #"{"jsonrpc":"2.0","id":"reload-1","method":"bridge.pageCommand.run","params":{"command":"reloadBridgeWebView"}}"#
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(from: json)
                == .runPageCommand(requestId: "reload-1", command: .reloadBridgeWebView))
    }

    @Test
    func pageCommandCannotSupplyAPaneOrExtraAuthority() {
        for params in [
            #"{"command":"reloadBridgeWebView","paneId":"other-pane"}"#,
            #"{"command":"reloadBridgeWebView","extra":true}"#, #"{}"#, #"{"command":false}"#,
        ] {
            let json =
                "{\"jsonrpc\":\"2.0\",\"id\":\"reload-1\",\"method\":\"bridge.pageCommand.run\",\"params\":\(params)}"
            #expect(
                BridgeReadyMessageHandler.decodeBootstrapMessage(from: json)
                    == .invalid(id: "reload-1", message: "Invalid request"))
        }
    }

    @Test
    func refusesEveryOtherAppCommandOnThePreSessionChannel() throws {
        for command in AppCommand.allCases where command != .reloadBridgeWebView {
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": "refused-1", "method": "bridge.pageCommand.run",
                "params": ["command": command.rawValue],
            ])
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(
                BridgeReadyMessageHandler.decodeBootstrapMessage(from: json)
                    == .invalid(id: "refused-1", message: "Invalid request"))
        }
    }

    @Test
    func acceptsReadyBootstrapRequestOnly() {
        let json = #"{"jsonrpc":"2.0","id":"ready-1","method":"bridge.ready","params":{}}"#

        let result = BridgeReadyMessageHandler.extractReadyRequestId(from: json)

        #expect(result == "ready-1")
    }

    @Test
    func rejectsOrdinaryCommandJSON() {
        let json = #"{"jsonrpc":"2.0","id":"cmd-1","method":"bridge.intakeReady","params":{"protocolId":"review"}}"#

        let result = BridgeReadyMessageHandler.extractReadyRequestId(from: json)

        #expect(result == nil)
    }

    @Test
    func rejectsInvalidAndNonStringBodies() {
        #expect(BridgeReadyMessageHandler.extractReadyRequestId(from: "not json {{{") == nil)
        #expect(BridgeReadyMessageHandler.extractReadyRequestId(from: "") == nil)
        #expect(BridgeReadyMessageHandler.extractReadyRequestId(from: ["method": "bridge.ready"]) == nil)
        #expect(BridgeReadyMessageHandler.extractReadyRequestId(from: true) == nil)
        #expect(
            BridgeReadyMessageHandler.extractReadyRequestId(from: #"{"jsonrpc":"2.0","method":"bridge.ready"}"#) == nil)
    }

    @Test
    func decodesMalformedReadyBootstrapAsInvalidRequest() {
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from: #"{"jsonrpc":"2.0","method":"bridge.ready","params":{}}"#)
                == .invalid(id: nil, message: "Invalid request"))
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from: #"{"jsonrpc":"2.0","id":true,"method":"bridge.ready","params":{}}"#)
                == .invalid(id: nil, message: "Invalid request: invalid id"))
    }

    @Test
    func rejectsReadyBootstrapWithExtraFieldsOrParams() {
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from: #"{"jsonrpc":"2.0","id":"ready-1","method":"bridge.ready","params":{"unexpected":true}}"#)
                == .invalid(id: "ready-1", message: "Invalid request"))
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"ready-1","method":"bridge.ready","params":{},"extra":true}"#
            ) == .invalid(id: "ready-1", message: "Invalid request"))
    }

    @Test
    func acceptsClosedProductSessionBootstrapRequests() {
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"bootstrap-1","method":"bridge.productSession.bootstrap","params":{"reason":"initial"}}"#
            ) == .productSessionBootstrap(requestId: "bootstrap-1", reason: .initial)
        )
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"bootstrap-2","method":"bridge.productSession.bootstrap","params":{"reason":"workerReplacement"}}"#
            ) == .productSessionBootstrap(requestId: "bootstrap-2", reason: .workerReplacement)
        )
    }

    @Test
    func rejectsOpenEndedProductSessionBootstrapRequests() {
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"bootstrap-1","method":"bridge.productSession.bootstrap","params":{"reason":"pageReload"}}"#
            ) == .invalid(id: "bootstrap-1", message: "Invalid request")
        )
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"bootstrap-1","method":"bridge.productSession.bootstrap","params":{"reason":"initial","extra":true}}"#
            ) == .invalid(id: "bootstrap-1", message: "Invalid request")
        )
    }

    @Test
    func acceptsClosedTelemetrySessionBootstrapRequests() {
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"telemetry-1","method":"bridge.telemetrySession.bootstrap","params":{"reason":"initial"}}"#
            ) == .telemetrySessionBootstrap(requestId: "telemetry-1", reason: .initial)
        )
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"telemetry-2","method":"bridge.telemetrySession.bootstrap","params":{"reason":"sidecarReplacement"}}"#
            ) == .telemetrySessionBootstrap(requestId: "telemetry-2", reason: .sidecarReplacement)
        )
    }

    @Test
    func rejectsOpenEndedTelemetrySessionBootstrapRequests() {
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"telemetry-1","method":"bridge.telemetrySession.bootstrap","params":{"reason":"workerReplacement"}}"#
            ) == .invalid(id: "telemetry-1", message: "Invalid request")
        )
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"telemetry-1","method":"bridge.telemetrySession.bootstrap","params":{"reason":"initial","extra":true}}"#
            ) == .invalid(id: "telemetry-1", message: "Invalid request")
        )
        #expect(
            BridgeReadyMessageHandler.decodeBootstrapMessage(
                from:
                    #"{"jsonrpc":"2.0","id":"telemetry-1","method":"bridge.telemetrySession.bootstrap","params":{"reason":"initial"},"extra":true}"#
            ) == .invalid(id: "telemetry-1", message: "Invalid request")
        )
    }
}
