import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioProgrammaticControl
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

    @Test("offline help's name inventory equals the real prepared app's composed debug methods")
    func offlineNameInventoryMatchesAppComposition() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let registry = try #require(harness.appDelegate.appIPCServer?.service.methodRegistry)
            let rendered = try IPCCompiledInvocationResolver().localHelp(arguments: ["help"])
            let help = try #require(rendered)
            let names = help.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("  "), let separator = line.range(of: " — ") else { return nil }
                return String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            #expect(Set(names) == Set(registry.capabilities.methods.map(\.name)))
            #expect(Set(names).count == names.count)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

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
            // materialized its cached byte result yet.
            #expect(capabilitiesCache.compositionCount == 0)
            #expect(!capabilitiesCache.hasComposedValue)

            let firstFrame = try await harness.responseFrame(method: "system.capabilities", params: .object([:]))
            let secondFrame = try await harness.responseFrame(method: "system.capabilities", params: .object([:]))
            let thirdFrame = try await harness.responseFrame(method: "system.capabilities", params: .object([:]))

            // The answer, not its byte layout: JSON object key order is not part of
            // the contract, and the transport frames the cached bytes.
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

    @Test(
        "catalog requests reuse encoded bytes and preserve the typed composition",
        arguments: ["system.capabilities", "command.list"])
    func repeatedCatalogRequestsReuseEncodedComposition(methodName: String) async throws {
        let commandInputs = AgentStudioIPCCommandCatalogProjection.captureBuildInputs(on: .debug)
        let commandResult = try await valueFromDedicatedThread {
            try AppIPCDescriptorCatalogBuilder.makeCommandComposition(inputs: commandInputs).catalogResult
        }
        let harness = try await SessionsVerticalHarness.make()
        do {
            let registry = try #require(harness.appDelegate.appIPCServer?.service.methodRegistry)
            let registration = try #require(registry.registration(named: methodName))
            let cache = try #require(registration.cachedTransportResult)
            #expect(cache.compositionCount == 0)
            #expect(cache.encodedCompositionCount == 0)

            for _ in 0..<3 {
                let frame = try await harness.responseFrame(method: methodName, params: .object([:]))
                let message = try JSONRPCCodec.decodeResponse(frame)
                #expect(message.id == .number(2))
                #expect(message.error == nil)
                let result = try #require(message.result)
                let resultData = try JSONEncoder().encode(result)
                if methodName == "system.capabilities" {
                    let served = try JSONDecoder().decode(IPCMethodCatalogResult.self, from: resultData)
                    #expect(served == registry.capabilities)
                } else {
                    let served = try JSONDecoder().decode(IPCCommandCatalogResult.self, from: resultData)
                    #expect(served == commandResult)
                }
                #expect(frame.utf8.count <= IPCFramePolicy.maximumResponseFrameBytes)
            }

            #expect(cache.compositionCount == 1)
            #expect(cache.encodedCompositionCount == 1)
            #expect(cache.hasComposedValue)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("App command composition normalization preserves the real catalog and nonmatching error")
    func commandDiscoveryNormalizationParity() async throws {
        let inputs = AgentStudioIPCCommandCatalogProjection.captureBuildInputs(on: .debug)
        let observation = try await valueFromDedicatedThread {
            let composition = try AppIPCDescriptorCatalogBuilder.makeCommandComposition(inputs: inputs)
            let catalog = composition.catalogResult
            let encoded = try composition.list.encodeResult(catalog)
            let schema = try IPCCommandCatalogResult.schema(
                compatibility: catalog.compatibility, commands: catalog.commands)
            let reference = try schema.normalize(encoded)
            let preparedSchema = try IPCValidatedJSONSchema(schema: schema)
            let prepared = try preparedSchema.normalize(encoded)
            let candidate = try composition.listRepresentations.erasedDescriptor.normalizeResult(encoded).data
            let decoded = try JSONDecoder().decode(IPCCommandCatalogResult.self, from: candidate)

            let document = try JSONSerialization.jsonObject(with: encoded)
            guard var fields = document as? [String: Any],
                var commands = fields["commands"] as? [[String: Any]], !commands.isEmpty
            else { throw CatalogNormalizationFixtureError.missingComposedCommands }
            commands[0]["id"] = "s6c.unrecognized-command"
            fields["commands"] = commands
            let nonmatching = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            let referenceError = try catalogNormalizationError { try schema.normalize(nonmatching) }
            let preparedError = try catalogNormalizationError { try preparedSchema.normalize(nonmatching) }
            let candidateError = try catalogNormalizationError {
                try composition.listRepresentations.erasedDescriptor.normalizeResult(nonmatching).data
            }
            return CatalogNormalizationObservation(
                normalizedBytesEqual: reference == candidate && reference == prepared,
                typedCompositionEqual: decoded == catalog,
                commandIdentifiers: Set(catalog.commands.map { $0.id.rawValue }),
                referenceError: referenceError, preparedError: preparedError, candidateError: candidateError
            )
        }
        #expect(observation.normalizedBytesEqual)
        #expect(observation.typedCompositionEqual)
        #expect(observation.commandIdentifiers == Set(inputs.commandDescriptorInputs.map { $0.id.rawValue }))
        let referenceError = try #require(observation.referenceError)
        let candidateError = try #require(observation.candidateError)
        let preparedError = try #require(observation.preparedError)
        #expect(referenceError.reason == .noMatchingAlternative)
        #expect(referenceError.fieldPath == "$.commands[0]")
        #expect(candidateError == referenceError)
        #expect(preparedError == referenceError)
    }
}

private struct CatalogNormalizationObservation: Sendable {
    let normalizedBytesEqual: Bool
    let typedCompositionEqual: Bool
    let commandIdentifiers: Set<String>
    let referenceError: IPCSchemaValidationError?
    let preparedError: IPCSchemaValidationError?
    let candidateError: IPCSchemaValidationError?
}

private enum CatalogNormalizationFixtureError: Error {
    case missingComposedCommands
}

private func catalogNormalizationError(_ normalize: () throws -> Data) throws -> IPCSchemaValidationError? {
    do {
        _ = try normalize()
        return nil
    } catch let error as IPCSchemaValidationError {
        return error
    }
}
