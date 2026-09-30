import AgentStudioProgrammaticControl
import Foundation

package struct IPCCommandDiscoveryError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    package enum Reason: String, Equatable, Sendable {
        case missingCommandList
        case missingCommandExecute
        case incompatibleMethodMetadata
        case invalidCommandCatalog
        case unknownCommandIdentifier
        case argumentVariantNotAllowed
        case invalidCommandResult
        case resultVariantNotAllowed
        case resultCommandIdentifierMismatch
        case resultCorrelationMismatch
    }

    package let reason: Reason
    package let fieldPath: String
    package let expected: String

    package var description: String {
        "\(reason.rawValue) at \(fieldPath): expected \(expected)"
    }
}

/// Compiles the two dynamic command methods from an already validated live
/// method catalog. General received metadata never becomes an invocation path.
package struct IPCCommandDiscovery: Sendable {
    package let commandListInvocation: IPCDescriptorInvocation

    private let advertisedList: IPCMethodCatalogEntry
    private let advertisedExecute: IPCMethodCatalogEntry

    package init(methodCatalog: IPCMethodCatalogResult) throws {
        guard methodCatalog.compatibility == .current else {
            throw Self.failure(
                .incompatibleMethodMetadata,
                fieldPath: "$.compatibility",
                expected: "the current protocol and catalog compatibility identity"
            )
        }
        advertisedList = try Self.uniqueEntry(
            named: "command.list",
            in: methodCatalog,
            missingReason: .missingCommandList
        )
        advertisedExecute = try Self.uniqueEntry(
            named: "command.execute",
            in: methodCatalog,
            missingReason: .missingCommandExecute
        )
        try Self.validateInvariantMetadata(
            list: advertisedList,
            execute: advertisedExecute
        )

        let listDescriptor: IPCMethodDescriptor<IPCEmptyParams, IPCCommandCatalogResult>
        do {
            listDescriptor = try IPCMethodDescriptor(
                name: advertisedList.name,
                description: advertisedList.description,
                parameterSchema: advertisedList.parameterSchema,
                resultSchema: advertisedList.resultSchema,
                examples: [],
                exposure: advertisedList.exposure,
                requiredPrivileges: Set(advertisedList.requiredPrivileges),
                dataScope: advertisedList.dataScope,
                allowedTargetKinds: Set(advertisedList.allowedTargetKinds),
                commandRelationship: advertisedList.commandRelationship,
                executionOwner: advertisedList.executionOwner,
                principalAvailability: advertisedList.principalAvailability,
                resultSemantics: advertisedList.resultSemantics,
                documentedErrors: advertisedList.documentedErrors,
                isMutating: advertisedList.isMutating,
                correlationPolicy: advertisedList.correlationPolicy,
                responseDelivery: advertisedList.responseDelivery,
                offlineEligibility: advertisedList.offlineEligibility,
                modelCalls: advertisedList.modelCalls
            )
        } catch {
            throw Self.failure(
                .incompatibleMethodMetadata,
                fieldPath: "$.methods",
                expected: "the typed command.list contract"
            )
        }
        let erasedList: IPCAnyMethodDescriptor
        do {
            erasedList = try IPCAnyMethodDescriptor(erasing: listDescriptor)
        } catch {
            throw Self.failure(
                .incompatibleMethodMetadata,
                fieldPath: "$.methods",
                expected: "the typed command.list contract"
            )
        }
        let normalizedParameters: IPCValidatedJSON
        do {
            normalizedParameters = try erasedList.normalizeParameters(Data("{}".utf8))
        } catch {
            throw Self.failure(
                .incompatibleMethodMetadata,
                fieldPath: "$.methods",
                expected: "command.list with empty typed parameters"
            )
        }
        commandListInvocation = IPCDescriptorInvocation(
            descriptor: erasedList,
            normalizedParameters: normalizedParameters,
            presentation: .tooling
        )
    }

    package func decodeCommandCatalog(
        from originalResult: Data
    ) throws -> IPCDiscoveredCommandCatalog {
        let normalizedResult: IPCValidatedJSON
        do {
            normalizedResult = try commandListInvocation.descriptor.normalizeResult(originalResult)
        } catch {
            throw Self.failure(
                .invalidCommandCatalog,
                fieldPath: "$.commands",
                expected: "the advertised typed command catalog"
            )
        }
        return try decodeCommandCatalog(from: normalizedResult)
    }

    package func decodeCommandCatalog(
        from normalizedResult: IPCValidatedJSON
    ) throws -> IPCDiscoveredCommandCatalog {
        let catalog: IPCCommandCatalogResult
        do {
            catalog = try advertisedList.resultSchema.decode(
                IPCCommandCatalogResult.self,
                from: normalizedResult.normalizedJSON
            )
        } catch {
            throw Self.failure(
                .invalidCommandCatalog,
                fieldPath: "$.commands",
                expected: "the advertised typed command catalog"
            )
        }

        return try decodeCommandCatalog(catalog)
    }

    private func decodeCommandCatalog(
        _ catalog: IPCCommandCatalogResult
    ) throws -> IPCDiscoveredCommandCatalog {

        guard catalog.compatibility == .current else {
            throw Self.failure(
                .invalidCommandCatalog,
                fieldPath: "$.compatibility",
                expected: "the current protocol and catalog compatibility identity"
            )
        }
        let identifiers = catalog.commands.map(\.id.rawValue)
        guard !identifiers.isEmpty,
            Set(identifiers).count == identifiers.count,
            identifiers == identifiers.sorted()
        else {
            throw Self.failure(
                .invalidCommandCatalog,
                fieldPath: "$.commands",
                expected: "unique command identifiers in ascending order"
            )
        }

        let validatedCommands: [IPCCommandDescriptor]
        do {
            validatedCommands = try catalog.commands.map { command in
                let validated = try IPCCommandDescriptorFactory.make(
                    IPCCommandDescriptorInput(
                        id: command.id,
                        title: command.title,
                        description: command.description,
                        exposure: command.exposure,
                        executionMode: command.executionMode,
                        argumentVariants: command.argumentVariants,
                        requiredPrivileges: Set(command.requiredPrivileges),
                        dataScope: command.dataScope,
                        allowedTargetKinds: Set(command.allowedTargetKinds),
                        resultVariants: command.resultVariants,
                        examples: command.examples,
                        agentEligibility: command.agentEligibility
                    )
                )
                guard validated == command else {
                    throw Self.failure(
                        .invalidCommandCatalog,
                        fieldPath: "$.commands",
                        expected: "command metadata derived from its typed variants and examples"
                    )
                }
                return validated
            }
        } catch let error as IPCCommandDiscoveryError {
            throw error
        } catch {
            throw Self.failure(
                .invalidCommandCatalog,
                fieldPath: "$.commands",
                expected: "validated typed command descriptors"
            )
        }

        let composition: IPCCommandMethodComposition
        let erasedList: IPCAnyMethodDescriptor
        let erasedExecute: IPCAnyMethodDescriptor
        do {
            composition = try IPCCommandMethodComposition(
                compatibility: catalog.compatibility,
                commands: validatedCommands,
                recognizedUnexposedCommands: catalog.recognizedUnexposedCommands
            )
            erasedList = try IPCAnyMethodDescriptor(erasing: composition.list)
            erasedExecute = try IPCAnyMethodDescriptor(erasing: composition.execute)
        } catch {
            throw Self.failure(
                .invalidCommandCatalog,
                fieldPath: "$.commands",
                expected: "one composable typed command catalog"
            )
        }
        guard erasedList.metadata == advertisedList,
            erasedExecute.metadata == advertisedExecute
        else {
            throw Self.failure(
                .incompatibleMethodMetadata,
                fieldPath: "$.methods",
                expected: "command.list and command.execute metadata exactly composed from the live command catalog"
            )
        }

        return IPCDiscoveredCommandCatalog(
            commands: validatedCommands,
            recognizedUnexposedCommands: catalog.recognizedUnexposedCommands,
            executeDescriptor: erasedExecute,
            requestEnvelopeDescriptor: try Self.compiledRequestEnvelope()
        )
    }

    /// See `IPCDiscoveredCommandCatalog.requestEnvelopeDescriptor`.
    private static func compiledRequestEnvelope() throws -> IPCAnyMethodDescriptor {
        do {
            return try IPCAnyMethodDescriptor(erasing: IPCCommandMethodComposition.recognizedHiddenExecute())
        } catch {
            throw failure(
                .invalidCommandCatalog,
                fieldPath: "$.commands",
                expected: "one composable typed command catalog"
            )
        }
    }

    private static func uniqueEntry(
        named name: String,
        in catalog: IPCMethodCatalogResult,
        missingReason: IPCCommandDiscoveryError.Reason
    ) throws -> IPCMethodCatalogEntry {
        let matches = catalog.methods.filter { $0.name == name }
        guard let entry = matches.first else {
            throw failure(
                missingReason,
                fieldPath: "$.methods",
                expected: "exactly one \(name) method"
            )
        }
        guard matches.count == 1 else {
            throw failure(
                .incompatibleMethodMetadata,
                fieldPath: "$.methods",
                expected: "unique method names"
            )
        }
        return entry
    }

    private static func validateInvariantMetadata(
        list: IPCMethodCatalogEntry,
        execute: IPCMethodCatalogEntry
    ) throws {
        let listIsCompatible =
            list.parameterSchema == (try IPCEmptyParams.ipcSchema())
            && list.exposure == .allChannels
            && list.requiredPrivileges == [.systemRead]
            && list.dataScope == .unspecified
            && list.allowedTargetKinds.isEmpty
            && list.commandRelationship == .noInteractiveIdentity
            && list.executionOwner == .queryReader
            && list.principalAvailability == .authenticated
            && list.resultSemantics == .applied
            && list.documentedErrors.isEmpty
            && !list.isMutating
            && list.correlationPolicy == .notAccepted
            && list.responseDelivery == .single
            && list.offlineEligibility == .never
            && list.modelCalls.isEmpty
        let executeIsCompatible =
            execute.exposure == .allChannels
            && execute.requiredPrivileges == [.appCommandExecute]
            && execute.dataScope == .unspecified
            && execute.commandRelationship == .appCommandParameter(field: "commandId")
            && execute.executionOwner == .appCommand
            && execute.principalAvailability == .authenticated
            && execute.resultSemantics == .discriminated
            && execute.documentedErrors == IPCCommandMethodComposition.executionErrors
            && execute.isMutating
            && execute.correlationPolicy == .required
            && execute.responseDelivery == .single
            && execute.offlineEligibility == .never
            && execute.modelCalls.isEmpty
        guard listIsCompatible, executeIsCompatible else {
            throw failure(
                .incompatibleMethodMetadata,
                fieldPath: "$.methods",
                expected: "the invariant typed command method metadata"
            )
        }
    }

    fileprivate static func failure(
        _ reason: IPCCommandDiscoveryError.Reason,
        fieldPath: String,
        expected: String
    ) -> IPCCommandDiscoveryError {
        IPCCommandDiscoveryError(
            reason: reason,
            fieldPath: fieldPath,
            expected: expected
        )
    }
}

package struct IPCDiscoveredCommandCatalog: Sendable {
    package let executeDescriptor: IPCAnyMethodDescriptor
    /// Reads a `command.execute` payload before the catalog has picked the
    /// command it names: the request typed against every argument variant
    /// this build compiles. `makeInvocation` then binds an advertised command
    /// to `executeDescriptor` and its own variants, and a recognized hidden
    /// command to this envelope.
    package let requestEnvelopeDescriptor: IPCAnyMethodDescriptor

    private let commandsByIdentifier: [IPCCommandIdentifier: IPCCommandDescriptor]
    /// Commands the app recognizes but this channel hides. The app, not this
    /// client, answers them: a pane agent hears `notYetAllowed` by name.
    private let recognizedUnexposedIdentifiers: Set<IPCCommandIdentifier>

    fileprivate init(
        commands: [IPCCommandDescriptor],
        recognizedUnexposedCommands: [IPCRecognizedUnexposedName],
        executeDescriptor: IPCAnyMethodDescriptor,
        requestEnvelopeDescriptor: IPCAnyMethodDescriptor
    ) {
        commandsByIdentifier = Dictionary(
            uniqueKeysWithValues: commands.map { ($0.id, $0) }
        )
        recognizedUnexposedIdentifiers = Set(
            recognizedUnexposedCommands.map { IPCCommandIdentifier(rawValue: $0.name) })
        self.executeDescriptor = executeDescriptor
        self.requestEnvelopeDescriptor = requestEnvelopeDescriptor
    }

    package func makeInvocation(
        commandId: IPCCommandIdentifier,
        correlationId: UUID,
        arguments: IPCCommandArguments
    ) throws -> IPCDescriptorInvocation {
        let request = IPCCommandExecutionRequest(
            commandId: commandId,
            correlationId: correlationId,
            arguments: arguments
        )
        guard let command = commandsByIdentifier[commandId] else {
            guard recognizedUnexposedIdentifiers.contains(commandId) else {
                throw IPCCommandDiscovery.failure(
                    .unknownCommandIdentifier,
                    fieldPath: "$.commandId",
                    expected: "an identifier advertised by command.list"
                )
            }
            // The channel publishes no descriptor for a hidden command, so its
            // request stays typed by the compiled envelope; the app refuses it
            // by name before it validates arguments.
            return IPCDescriptorInvocation(
                descriptor: requestEnvelopeDescriptor,
                normalizedParameters: try Self.normalize(request, through: requestEnvelopeDescriptor),
                presentation: .tooling
            )
        }
        guard command.argumentVariants.contains(arguments.variant) else {
            throw IPCCommandDiscovery.failure(
                .argumentVariantNotAllowed,
                fieldPath: "$.arguments.kind",
                expected: "an argument variant advertised for the selected command"
            )
        }
        return IPCDescriptorInvocation(
            descriptor: executeDescriptor,
            normalizedParameters: try Self.normalize(request, through: executeDescriptor),
            presentation: .tooling
        )
    }

    private static func normalize(
        _ request: IPCCommandExecutionRequest,
        through descriptor: IPCAnyMethodDescriptor
    ) throws -> IPCValidatedJSON {
        do {
            return try descriptor.normalizeParameters(JSONEncoder().encode(request))
        } catch {
            throw IPCCommandDiscovery.failure(
                .argumentVariantNotAllowed,
                fieldPath: "$.arguments",
                expected: "arguments matching the selected command descriptor"
            )
        }
    }

    package func decodeResult(
        _ originalResult: Data,
        for invocation: IPCDescriptorInvocation
    ) throws -> IPCCommandExecutionResult {
        let normalizedResult: IPCValidatedJSON
        do {
            normalizedResult = try executeDescriptor.normalizeResult(originalResult)
        } catch {
            throw IPCCommandDiscovery.failure(
                .invalidCommandResult,
                fieldPath: "$",
                expected: "the typed command.execute result"
            )
        }
        return try decodeResult(normalizedResult, for: invocation)
    }

    package func decodeResult(
        _ normalizedResult: IPCValidatedJSON,
        for invocation: IPCDescriptorInvocation
    ) throws -> IPCCommandExecutionResult {
        guard invocation.descriptor.metadata == executeDescriptor.metadata else {
            throw IPCCommandDiscovery.failure(
                .invalidCommandResult,
                fieldPath: "$",
                expected: "the command.execute descriptor used by this live catalog"
            )
        }
        let request: IPCCommandExecutionRequest
        let result: IPCCommandExecutionResult
        do {
            request = try JSONDecoder().decode(
                IPCCommandExecutionRequest.self,
                from: invocation.normalizedParameters.data(
                    validatedFor: executeDescriptor.metadata.parameterSchema
                )
            )
            result = try JSONDecoder().decode(
                IPCCommandExecutionResult.self,
                from: normalizedResult.data(
                    validatedFor: executeDescriptor.metadata.resultSchema
                )
            )
        } catch {
            throw IPCCommandDiscovery.failure(
                .invalidCommandResult,
                fieldPath: "$",
                expected: "the typed command.execute result"
            )
        }
        guard let command = commandsByIdentifier[request.commandId] else {
            throw IPCCommandDiscovery.failure(
                .unknownCommandIdentifier,
                fieldPath: "$.commandId",
                expected: "an identifier advertised by command.list"
            )
        }
        guard command.resultVariants.contains(result.variant) else {
            throw IPCCommandDiscovery.failure(
                .resultVariantNotAllowed,
                fieldPath: "$.kind",
                expected: "a result variant advertised for the selected command"
            )
        }
        guard result.commandId == request.commandId else {
            throw IPCCommandDiscovery.failure(
                .resultCommandIdentifierMismatch,
                fieldPath: "$.commandId",
                expected: "the initiating command identifier"
            )
        }
        guard result.correlationId == request.correlationId else {
            throw IPCCommandDiscovery.failure(
                .resultCorrelationMismatch,
                fieldPath: "$.correlationId",
                expected: "the initiating command correlation"
            )
        }
        return result
    }
}
