import Foundation

struct PaneTargetFlags {
    static let environmentPaneVariable = "AGENTSTUDIO_PANE_ID"

    enum Refusal: Error, Equatable {
        case targetFlags
        case missingEnvironment
        case paneNotFound(String)
    }

    private var target: String?
    private var usesEnvironment = false
    private var targetFlagCount = 0

    mutating func consume(_ argument: String, remaining: inout [String]) throws(Refusal) -> Bool {
        switch argument {
        case "--target":
            targetFlagCount += 1
            guard !remaining.isEmpty else { throw .targetFlags }
            target = remaining.removeFirst()
        case "--target-env":
            targetFlagCount += 1
            usesEnvironment = true
        default: return false
        }
        return true
    }

    func resolve(environment: [String: String]) throws(Refusal) -> UUID {
        guard targetFlagCount == 1 else { throw .targetFlags }
        let resolvedTarget: String?
        if usesEnvironment {
            guard let value = environment[Self.environmentPaneVariable], !value.isEmpty else {
                throw .missingEnvironment
            }
            resolvedTarget = value
        } else {
            resolvedTarget = target
        }
        guard let resolvedTarget, let paneId = UUID(uuidString: resolvedTarget) else {
            throw .paneNotFound(resolvedTarget ?? "")
        }
        return paneId
    }
}
