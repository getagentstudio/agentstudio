import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// The catalog methods are the only responses this app composes that are
/// legitimately larger than any request. Every other capabilities test runs in
/// process against the composition and never reaches `NDJSONFrameEncoder`,
/// which is how a server that answered `system.capabilities` with a framing
/// failure shipped with a green suite.
@MainActor
@Suite("App IPC catalog frame transport", .serialized)
struct AgentStudioIPCCatalogFrameTransportTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("system.capabilities crosses the socket in one frame larger than the request bound")
    func systemCapabilitiesCrossesTheSocket() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let frame = try await harness.responseFrame(method: "system.capabilities", params: .object([:]))
            let frameByteCount = frame.utf8.count

            // Asserting the size proves the case is real: a catalog that fits the
            // request bound would not have exercised the outbound bound at all.
            #expect(
                frameByteCount > IPCFramePolicy.maximumRequestFrameBytes,
                "system.capabilities frame measured \(frameByteCount) bytes"
            )
            #expect(frameByteCount <= IPCFramePolicy.maximumResponseFrameBytes)

            let message = try JSONRPCCodec.decodeResponse(frame)
            #expect(message.error == nil)
            let result = try #require(message.result)
            let catalog = try JSONDecoder().decode(
                IPCMethodCatalogResult.self, from: try JSONEncoder().encode(result)
            )
            #expect(catalog.methods.contains { $0.name == "system.capabilities" })
            #expect(catalog.methods.contains { $0.name == "session.message" })
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    /// The catalog cannot change while a runtime is up, so the encoding that
    /// turns it into a wire response is done once. Three requests must return
    /// the same answer, and the server must have composed it exactly once.
    ///
    /// Counted, not timed. How long a request takes is a property of the
    /// machine; how many times the catalog was encoded is the property this
    /// test is about.
    @Test("repeated capabilities requests are served from one composition")
    func repeatedCapabilitiesRequestsServeOneComposition() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let capabilitiesCache = try #require(
                harness.appDelegate.appIPCServer?.service.methodRegistry.capabilitiesTransportResultCache
            )

            // Startup composition already validated the catalog bytes; the cache has not
            // materialized their JSONValue projection yet.
            #expect(capabilitiesCache.compositionCount == 0)
            #expect(!capabilitiesCache.hasComposedValue)

            let firstFrame = try await harness.responseFrame(method: "system.capabilities", params: .object([:]))
            let secondFrame = try await harness.responseFrame(method: "system.capabilities", params: .object([:]))
            let thirdFrame = try await harness.responseFrame(method: "system.capabilities", params: .object([:]))

            // The answer, not its byte layout: JSON object key order is not part of
            // the contract, and the transport re-serializes the cached value.
            let firstResult = try JSONRPCCodec.decodeResponse(firstFrame).result
            let secondResult = try JSONRPCCodec.decodeResponse(secondFrame).result
            let thirdResult = try JSONRPCCodec.decodeResponse(thirdFrame).result
            #expect(firstResult != nil)
            #expect(firstResult == secondResult)
            #expect(secondResult == thirdResult)

            // Three requests crossed the socket; the cached transport value was
            // materialized once from the validated composition result.
            #expect(capabilitiesCache.compositionCount == 1)
            #expect(capabilitiesCache.hasComposedValue)

            // The size is what makes reuse worth proving: this is the one response
            // larger than any request the transport accepts.
            #expect(firstFrame.utf8.count > IPCFramePolicy.maximumRequestFrameBytes)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("command.list crosses the socket and carries the debug command catalog")
    func commandListCrossesTheSocket() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let frame = try await harness.responseFrame(method: "command.list", params: .object([:]))
            let message = try JSONRPCCodec.decodeResponse(frame)

            #expect(message.error == nil)
            let result = try #require(message.result)
            guard case .object(let fields) = result, case .array(let commands)? = fields["commands"] else {
                Issue.record("command.list result did not carry a commands array")
                await harness.tearDown()
                return
            }
            #expect(commands.count == 154)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }
}
