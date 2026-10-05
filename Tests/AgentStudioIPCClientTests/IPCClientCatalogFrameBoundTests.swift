import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

/// The CLI resolves every method outside its five bootstrap descriptors through
/// `system.capabilities`, so the reader that receives that response decides
/// whether the whole tool works. It reads against the outbound bound, not the
/// bound the server enforces on requests.
@Suite("IPC client catalog frame bound", .serialized)
struct IPCClientCatalogFrameBoundTests {
    @Test("discovery accepts a capabilities response larger than the request bound")
    func discoveryAcceptsCapabilitiesAboveTheRequestBound() throws {
        let catalog = try makeBuiltInCatalog()
        let ping = try IPCAnyMethodDescriptor(erasing: catalog.systemAndAuth.systemPing)
        let composition = try IPCSystemCapabilitiesDescriptorFactory.compose(
            compatibility: .current,
            availableDescriptors: catalog.erasedDescriptors,
            illustrativeDescriptor: ping
        )
        let resultValue = paddedBeyondRequestBound(
            try JSONRPCCodec.encodeJSONValue(composition.result)
        )
        let responsePayload = try JSONRPCCodec.encodeResponse(
            .success(id: .number(1), result: resultValue)
        )
        let responseByteCount = responsePayload.utf8.count + 1
        #expect(
            responseByteCount > IPCFramePolicy.maximumRequestFrameBytes,
            "padded capabilities frame measured \(responseByteCount) bytes"
        )

        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        try listener.start { connection in
            defer { connection.close() }
            var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
            let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
            #expect(request.method == "system.capabilities")
            try connection.send(
                NDJSONFrameEncoder.encode(
                    responsePayload,
                    maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes
                ))
        }
        defer { listener.stop() }

        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: endpoint.path), descriptors: catalog.erasedDescriptors
        )
        let discovered = try client.discoverCatalog()

        #expect(discovered.methods.count == composition.result.methods.count)
        #expect(discovered.compatibility == IPCProtocolCatalogCompatibility.current)
    }

    /// Inflates one method description so the encoded catalog exceeds the
    /// request bound without inventing a shape the decoder would reject.
    private func paddedBeyondRequestBound(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value,
            case .array(var methods)? = fields["methods"],
            case .object(var firstMethod) = methods.first,
            case .string(let description)? = firstMethod["description"]
        else {
            Issue.record("capabilities result did not carry a describable method array")
            return value
        }
        let padding = String(
            repeating: "a", count: IPCFramePolicy.maximumRequestFrameBytes + 4096
        )
        firstMethod["description"] = .string(description + padding)
        methods[0] = .object(firstMethod)
        fields["methods"] = .array(methods)
        return .object(fields)
    }

    private func makeBuiltInCatalog() throws -> IPCBuiltInMethodCatalog {
        try IPCBuiltInMethodCatalog(
            inputs: .init(
                relationships: .init(
                    paneFocus: .noInteractiveIdentity, paneClose: .noInteractiveIdentity,
                    drawerToggle: .noInteractiveIdentity, drawerAddPane: .noInteractiveIdentity,
                    bridgeDiffLoad: .noInteractiveIdentity, bridgeFileViewOpen: .noInteractiveIdentity),
                examples: .init(illustrativeIdentifier: UUIDv7.generate())
            ))
    }
}
