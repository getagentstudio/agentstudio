import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

struct AgentStudioAppIPCRequestError: Error, Equatable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static let unauthenticated = Self(code: -32_001, message: "unauthenticated")
    static let unauthorized = Self(code: -32_002, message: "unauthorized")
    static let methodNotFound = Self(
        code: -32_601,
        message: "method not found",
        data: .object([
            "reason": .string("unknownMethod"),
            "fieldPath": .string("$.method"),
            "catalogMethod": .string("system.capabilities"),
        ])
    )
    static let invalidParams = Self(code: -32_602, message: "invalid params")
    static let responseEncodingFailed = Self(code: -32_603, message: "response encoding failed")
}

extension AgentStudioAppIPCRequestError {
    init(_ error: Error) {
        switch error {
        case let authorizationError as AuthorizationError:
            self.init(authorizationError)
        case let queryError as AppIPCQueryError:
            self.init(queryError.reason)
        case let layoutError as AppIPCLayoutError:
            self.init(layoutError.reason)
        case let runtimeError as AppIPCRuntimeError:
            self.init(runtimeError.reason)
        case let commandError as AppIPCCommandError:
            self.init(commandError.reason)
        case let bridgeError as AppIPCBridgeError:
            self.init(bridgeError.reason)
        case let sessionsError as AppIPCSessionsError:
            self.init(sessionsError.reason)
        case let uiPresentationError as AppIPCUIPresentationError:
            self.init(uiPresentationError.reason)
        case let authError as AgentStudioIPCAuthenticationError:
            self.init(authError.reason)
        case let registrationError as AppIPCTypedMethodRegistrationError:
            switch registrationError {
            case .authenticationRequired: self = .unauthenticated
            case .methodNotExposed: self = .methodNotFound
            default: self = .invalidParams
            }
        case let schemaError as IPCSchemaValidationError:
            self.init(
                code: -32_602, message: "invalid params",
                data: .object([
                    "fieldPath": .string(schemaError.fieldPath),
                    "reason": .string(schemaError.reason.rawValue),
                    "expected": .string(schemaError.expected),
                ]))
        case is IPCTargetSelectorError:
            self = .invalidParams
        case is PermissionBrokerError, is IPCEventBrokerError:
            self = .unauthorized
        case is IPCHandleError:
            self = Self(code: -32_004, message: "target not found")
        case let frameError as NDJSONFrameError:
            self.init(frameError)
        default:
            self = Self(code: -32_603, message: "internal error")
        }
    }

    /// A frame this process composed itself overflowed the outbound bound.
    /// Without this arm the throw reached the `default` arm and a finite,
    /// measurable size condition reported as an opaque internal error.
    private init(_ error: NDJSONFrameError) {
        switch error.reason {
        case .frameTooLarge:
            self = Self(
                code: -32_008,
                message: "response too large",
                data: .object([
                    "reason": .string("responseTooLarge"),
                    "frameByteCount": .number(Double(error.frameByteCount)),
                    "maximumFrameBytes": .number(Double(error.maximumFrameBytes)),
                ])
            )
        case .embeddedNewline, .invalidUTF8:
            self = .responseEncodingFailed
        }
    }

    private init(_ error: AuthorizationError) {
        switch error.reason {
        case .methodNotFound:
            self = .methodNotFound
        case .unauthorized, .noBoundPane:
            self = .unauthorized
        case .missingGrant:
            guard let requiredScope = error.requiredScope,
                let scopeValue = try? JSONRPCCodec.encodeJSONValue(requiredScope)
            else {
                self = .unauthorized
                return
            }
            self = Self(
                code: -32_002,
                message: "missing grant",
                data: .object([
                    "reason": .string("missingGrant"),
                    "fieldPath": .string("$.authorization"),
                    "requiredScope": scopeValue,
                ])
            )
        case .notYetAllowed:
            self = Self.agentRefusal(
                code: -32_011, message: "not yet allowed", reason: "notYetAllowed", name: error.refusedName)
        case .refusedForAgent:
            self = Self.agentRefusal(
                code: -32_012, message: "refused for agent", reason: "refusedForAgent", name: error.refusedName)
        }
    }

    /// The agent outcomes name the refused method or command so an agent can
    /// tell them apart from authentication and missing-target failures.
    private static func agentRefusal(code: Int, message: String, reason: String, name: String?) -> Self {
        var data: [String: JSONValue] = ["reason": .string(reason)]
        if let name { data["name"] = .string(name) }
        return Self(code: code, message: message, data: .object(data))
    }

    private init(_ reason: AppIPCQueryError.Reason) {
        switch reason {
        case .noActiveWindow:
            self = Self(code: -32_006, message: "no active window")
        case .targetNotFound:
            self = Self(code: -32_004, message: "target not found")
        }
    }

    private init(_ reason: AppIPCLayoutError.Reason) {
        switch reason {
        case .noActiveWindow:
            self = Self(code: -32_006, message: "no active window")
        case .targetNotFound:
            self = Self(code: -32_004, message: "target not found")
        case .validationRejected:
            self = Self(code: -32_007, message: "validation rejected")
        }
    }

    private init(_ reason: AppIPCRuntimeError.Reason) {
        switch reason {
        case .targetNotFound:
            self = Self(
                code: -32_004,
                message: "target not found",
                data: .object(["reason": .string(AppIPCRuntimeError.Reason.targetNotFound.rawValue)])
            )
        case .noRuntime, .runtimeNotReady:
            self = Self(
                code: -32_005,
                message: "runtime not ready",
                data: .object(["reason": .string(AppIPCRuntimeError.Reason.runtimeNotReady.rawValue)])
            )
        case .unsupportedCommand:
            self = Self(code: -32_003, message: "unsupported capability")
        case .backendUnavailable:
            self = Self(
                code: -32_005,
                message: "backend unavailable",
                data: .object(["reason": .string(AppIPCRuntimeError.Reason.runtimeNotReady.rawValue)])
            )
        case .validationRejected:
            self = Self(
                code: -32_007,
                message: "validation rejected",
                data: .object(["reason": .string("invalidParams")])
            )
        case .timeout:
            self = Self(
                code: -32_009,
                message: "timeout",
                data: .object(["reason": .string(AppIPCRuntimeError.Reason.timeout.rawValue)])
            )
        case .replayGap:
            self = Self(
                code: -32_010,
                message: "replay gap",
                data: .object(["reason": .string(AppIPCRuntimeError.Reason.replayGap.rawValue)])
            )
        }
    }

    private init(_ reason: AppIPCSessionsError.Reason) {
        switch reason {
        case .targetNotFound:
            self = Self(code: -32_004, message: "target not found")
        case .bindingRequired:
            self = Self(
                code: -32_003, message: "no bound conversation",
                data: .object([
                    "reason": .string(IPCSessionFailureReason.bindingRequired),
                    "fieldPath": .string("$.handle"),
                ]))
        case .correlationConflict:
            self = Self(
                code: -32_007, message: "correlation conflict",
                data: .object([
                    "reason": .string(IPCSessionFailureReason.correlationConflict),
                    "fieldPath": .string("$.correlationId"),
                ]))
        case .ingestionUnavailable:
            self = Self(code: -32_005, message: "sessions ingestion unavailable")
        case .validationRejected:
            self = Self(code: -32_007, message: "validation rejected")
        }
    }

    private init(_ reason: AppIPCCommandError.Reason) {
        switch reason {
        case .noActiveWindow:
            self = Self(code: -32_006, message: "no active window")
        case .targetNotFound:
            self = Self(
                code: -32_004, message: "target not found",
                data: .object(["reason": .string("targetNotFound"), "fieldPath": .string("$.arguments")]))
        case .unknownCommand:
            self = Self(
                code: -32_003,
                message: "unsupported capability",
                data: .object([
                    "reason": .string("unknownCommand"),
                    "fieldPath": .string("$.commandId"),
                    "catalogMethod": .string("command.list"),
                ])
            )
        case .unsupportedCommand:
            self = Self(
                code: -32_003, message: "unsupported capability",
                data: .object([
                    "reason": .string("unsupportedCommand"), "fieldPath": .string("$.commandId"),
                    "catalogMethod": .string("command.list"),
                ]))
        case .requiresPresentation:
            self = Self(code: -32_003, message: "requires presentation")
        case .requiresTarget:
            self = Self(code: -32_004, message: "target required")
        case .requiresParameters:
            self = Self(code: -32_007, message: "parameters required")
        case .validationRejected:
            self = Self(code: -32_007, message: "validation rejected")
        case .stateUnavailable:
            self = Self(
                code: -32_005,
                message: "state unavailable",
                data: .object([
                    "reason": .string("stateUnavailable"),
                    "fieldPath": .string("$.commandId"),
                ])
            )
        }
    }

    private init(_ reason: AppIPCBridgeError.Reason) {
        switch reason {
        case .noActiveWindow:
            self = Self(code: -32_006, message: "no active window")
        case .targetNotFound:
            self = Self(code: -32_004, message: "target not found")
        case .unsupportedTarget:
            self = Self(code: -32_003, message: "unsupported target")
        case .packageUnavailable:
            self = Self(code: -32_005, message: "package unavailable")
        case .itemNotFound:
            self = Self(code: -32_004, message: "item not found")
        case .contentUnavailable:
            self = Self(code: -32_005, message: "content unavailable")
        case .payloadTooLarge:
            self = Self(code: -32_008, message: "payload too large")
        case .validationRejected:
            self = Self(code: -32_007, message: "validation rejected")
        }
    }

    private init(_ reason: AppIPCUIPresentationError.Reason) {
        switch reason {
        case .noActiveWindow:
            self = Self(code: -32_006, message: "no active window")
        case .targetNotFound:
            self = Self(code: -32_004, message: "target not found")
        case .validationRejected:
            self = Self(code: -32_007, message: "validation rejected")
        }
    }

    private init(_ reason: AgentStudioIPCAuthenticationError.Reason) {
        switch reason {
        case .unauthenticated, .peerUserMismatch:
            self = .unauthenticated
        }
    }
}
