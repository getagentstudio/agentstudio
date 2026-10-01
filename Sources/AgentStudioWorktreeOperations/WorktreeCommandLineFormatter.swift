import Foundation

package struct WorktreeCommandLineResponse: Sendable, Equatable {
    package let text: String
    package let exitCode: Int32

    package init(text: String, exitCode: Int32) {
        self.text = text
        self.exitCode = exitCode
    }
}

package enum WorktreeCommandLineFormatter {
    package static func format(
        outcome: WorktreeOperationOutcome,
        usesJSONOutput: Bool
    ) throws -> WorktreeCommandLineResponse {
        let exitCode: Int32
        switch outcome {
        case .created, .listed:
            exitCode = 0
        case .listFailed:
            exitCode = 2
        case .removal(let report):
            exitCode = report.exitCode
        case .refused:
            exitCode = 1
        case .failed:
            exitCode = 2
        }

        let text = usesJSONOutput ? try jsonText(for: outcome) : humanLine(for: outcome)
        return WorktreeCommandLineResponse(text: text, exitCode: exitCode)
    }

    package static func format(
        removalReport: WorktreeRemovalReport,
        usesJSONOutput: Bool
    ) throws -> WorktreeCommandLineResponse {
        let text: String
        if usesJSONOutput {
            text = try encodeJSON(removalReport)
        } else {
            text = removalHumanLines(removalReport)
        }
        return WorktreeCommandLineResponse(text: text, exitCode: removalReport.exitCode)
    }

    private static func humanLine(for outcome: WorktreeOperationOutcome) -> String {
        switch outcome {
        case .created(let summary):
            createdHumanLine(summary)
        case .listed(let summary):
            listedHumanLine(summary)
        case .listFailed(let failure):
            listFailureHumanLine(failure)
        case .removal(let report):
            removalHumanLines(report)
        case .refused(let refusal):
            refusedHumanLine(refusal)
        case .failed(let failure):
            failedHumanLine(failure)
        }
    }

    private static func jsonText(for outcome: WorktreeOperationOutcome) throws -> String {
        switch outcome {
        case .created(let summary):
            try createdJSONText(summary)
        case .listed(let summary):
            try listedJSONText(summary)
        case .listFailed(let failure):
            try listFailureJSONText(failure)
        case .removal(let report):
            try encodeJSON(report)
        case .refused(let refusal):
            try refusedJSONText(refusal)
        case .failed(let failure):
            try failedJSONText(failure)
        }
    }

    package static func encodeJSON<TDocument: Encodable>(_ document: TDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard let encodedText = String(data: data, encoding: .utf8) else {
            throw WorktreeCommandLineFormattingError.invalidUTF8
        }
        return encodedText
    }

    package static func absolutePath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

private enum WorktreeCommandLineFormattingError: Error {
    case invalidUTF8
}
