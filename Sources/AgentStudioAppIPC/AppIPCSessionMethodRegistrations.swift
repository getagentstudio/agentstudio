import AgentStudioProgrammaticControl
import Foundation

package struct AppIPCSessionsError: Error, Equatable, Sendable {
    package enum Reason: String, Equatable, Sendable {
        case targetNotFound
        case bindingRequired
        case correlationConflict
        case ingestionUnavailable
        case validationRejected
    }

    package let reason: Reason

    package init(reason: Reason) {
        self.reason = reason
    }
}

package enum IPCSessionEventProvenance: Sendable, Equatable {
    case matchingPane
    case other
}

/// Sessions ingestion and its one read, addressed by canonical pane UUID. The
/// App composition owns the mapping to Sessions mutations; this boundary never
/// sees a domain mutation or a SQLite row.
package protocol AppIPCSessionsPort: Sendable {
    func recordDeliberateReport(
        paneId: UUID,
        params: IPCSessionReportParams
    ) async throws -> IPCSessionReportResult

    func recordAgentMessage(
        paneId: UUID,
        params: IPCSessionMessageParams
    ) async throws -> IPCSessionMessageResult

    func recordProviderEvent(
        paneId: UUID,
        params: IPCSessionEventParams,
        provenance: IPCSessionEventProvenance
    ) async throws -> IPCSessionEventResult

    func readSessionState(
        paneId: UUID,
        params: IPCSessionQueryParams
    ) async throws -> IPCSessionQueryResult
}

extension AppIPCBuiltInMethodRegistrations {
    static func sessionRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog.sessions
        let port = inputs.ports.sessionsPort
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.sessionReport),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCSessionReportParams(
                                handle: canonicalHandle,
                                kind: original.kind,
                                explanation: original.explanation,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, _, target in
                    try await port.recordDeliberateReport(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target),
                        params: parameters
                    )
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.sessionMessage),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCSessionMessageParams(
                                handle: canonicalHandle,
                                text: original.text,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, _, target in
                    try await port.recordAgentMessage(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target),
                        params: parameters
                    )
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.sessionEvent),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCSessionEventParams(
                                handle: canonicalHandle,
                                provider: original.provider,
                                event: original.event,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, context, target in
                    let paneId = try AppIPCSessionTargetSupport.paneId(from: target)
                    return try await port.recordProviderEvent(
                        paneId: paneId,
                        params: parameters,
                        provenance: AppIPCSessionTargetSupport.provenance(
                            principal: context.principal,
                            paneId: paneId
                        )
                    )
                }
            ).erase(),
            sessionQueryRegistration(inputs: inputs),
        ]
    }

    private static func sessionQueryRegistration(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> AnyAppIPCMethodRegistration {
        try AppIPCTypedMethodRegistration(
            descriptorRepresentations: try inputs.descriptorRepresentations(for: inputs.catalog.sessions.sessionQuery),
            correlation: .notRequired,
            resolveTarget: { parameters, _, tools in
                try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                    parameters,
                    rawHandle: parameters.handle,
                    tools: tools,
                    replacingHandle: { _, canonicalHandle in
                        IPCSessionQueryParams(handle: canonicalHandle)
                    }
                )
            },
            connectionHandler: { parameters, _, target in
                try await inputs.ports.sessionsPort.readSessionState(
                    paneId: AppIPCSessionTargetSupport.paneId(from: target),
                    params: parameters
                )
            }
        ).erase()
    }
}

enum AppIPCSessionTargetSupport {
    /// Target resolution already canonicalized the pane, so a non-pane target
    /// here is a registration defect rather than caller input.
    static func paneId(from target: IPCTargetScope) throws -> UUID {
        guard case .pane(let rawPaneId) = target, let paneId = UUID(uuidString: rawPaneId) else {
            throw AppIPCTypedMethodRegistrationError.targetKindNotAllowed
        }
        return paneId
    }

    static func provenance(principal: IPCPrincipal?, paneId: UUID) -> IPCSessionEventProvenance {
        guard let principal,
            case .spawnedPaneAgent(let boundPaneId, _) = principal.kind,
            UUID(uuidString: boundPaneId) == paneId
        else { return .other }
        return .matchingPane
    }
}
