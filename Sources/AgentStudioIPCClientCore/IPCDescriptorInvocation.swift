import AgentStudioProgrammaticControl
import Foundation

package struct IPCDescriptorInvocation: Sendable {
    package let descriptor: IPCAnyMethodDescriptor
    package let normalizedParameters: IPCValidatedJSON
    package let presentation: IPCDescriptorInvocationPresentation

    package init(
        descriptor: IPCAnyMethodDescriptor,
        normalizedParameters: IPCValidatedJSON,
        presentation: IPCDescriptorInvocationPresentation
    ) {
        self.descriptor = descriptor
        self.normalizedParameters = normalizedParameters
        self.presentation = presentation
    }
}

package enum IPCDescriptorInvocationPresentation: Equatable, Sendable {
    case tooling
    case model(IPCModelInvocationPresentation)
}

package struct IPCModelInvocationPresentation: Equatable, Sendable {
    package let variant: IPCModelCallVariant
    package let successReply: String
    package let queuedReply: String?
    package let isOfflineEligible: Bool
    package let showsDetail: Bool

    package init(
        variant: IPCModelCallVariant,
        successReply: String,
        queuedReply: String?,
        isOfflineEligible: Bool,
        showsDetail: Bool
    ) {
        self.variant = variant
        self.successReply = successReply
        self.queuedReply = queuedReply
        self.isOfflineEligible = isOfflineEligible
        self.showsDetail = showsDetail
    }
}

package struct IPCDescriptorInvocationError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    package enum Reason: String, Equatable, Sendable {
        case unknownMethod
        case unknownField
        case missingValue
        case invalidValue
        case unsupportedScalarField
        case conflictingInputMode
        case unavailableStandardInput
        case ambiguousInvocation
    }

    package let reason: Reason
    package let fieldPath: String
    package let expected: String

    package init(reason: Reason, fieldPath: String, expected: String) {
        self.reason = reason
        self.fieldPath = fieldPath
        self.expected = expected
    }

    package var description: String {
        "\(reason.rawValue) at \(fieldPath): expected \(expected)"
    }
}
