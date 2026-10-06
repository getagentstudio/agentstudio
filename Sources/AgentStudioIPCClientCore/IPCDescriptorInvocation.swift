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

    static func unknownMethod(named name: String, index: IPCBuiltInMethodIndex) -> Self {
        let rankedMethods: [(methodName: String, distance: Int)] = index.methodNames.map { methodName in
            let distance: Int = editDistance(name, methodName)
            return (methodName: methodName, distance: distance)
        }
        let sortedMethods: [(methodName: String, distance: Int)] = rankedMethods.sorted { first, second in
            if first.distance == second.distance { return first.methodName < second.methodName }
            return first.distance < second.distance
        }
        let nearestMethods: ArraySlice<(methodName: String, distance: Int)> = sortedMethods.prefix(3)
        let closestNames: [String] = nearestMethods.map { $0.methodName }
        return Self(
            reason: .unknownMethod, fieldPath: "$.method",
            expected: "a compiled method or model invocation; see agentstudio help; closest methods: "
                + closestNames.joined(separator: ", "))
    }

    private static func editDistance(_ candidate: String, _ method: String) -> Int {
        let methodCharacters = Array(method)
        var previous = Array(0...methodCharacters.count)
        for (row, character) in candidate.enumerated() {
            var current = [row + 1]
            for (column, methodCharacter) in methodCharacters.enumerated() {
                let deletionCost: Int = previous[column + 1] + 1
                let insertionCost: Int = current[column] + 1
                let replacementCost: Int = previous[column] + (character == methodCharacter ? 0 : 1)
                let lowestCost: Int = min(deletionCost, min(insertionCost, replacementCost))
                current.append(lowestCost)
            }
            previous = current
        }
        return previous[methodCharacters.count]
    }
}
