import Foundation

/// Enables hooks without reformatting TOML or interpreting string contents as tables.
package enum CodexFeatureTableEditor {
    package enum Outcome: Equatable, Sendable {
        case alreadyEnabled, enabledInExistingTable, appendedFeaturesTable
        package var describesAChange: Bool { self != .alreadyEnabled }
    }

    package static func enablingHooks(
        in contents: String, configurationPath: String
    ) throws -> (contents: String, outcome: Outcome) {
        do { return try edit(contents) } catch {
            throw AgentPackageInstallationError.featuresTableNotLocatable(configurationPath)
        }
    }

    private static func edit(_ contents: String) throws -> (contents: String, outcome: Outcome) {
        let scanner = try CodexTOMLLineScanner(contents)
        let terminator = contents.contains("\r\n") ? "\r\n" : "\n"
        guard let table = try scanner.table(named: "features") else {
            let separator = contents.isEmpty ? "" : (contents.hasSuffix("\n") ? terminator : terminator + terminator)
            return (contents + separator + "[features]\(terminator)hooks = true\(terminator)", .appendedFeaturesTable)
        }
        let assignments = try table.body.compactMap { line -> (CodexTOMLLineScanner.Line, Int)? in
            guard let assignment = try scanner.assignment(in: line), assignment.key.first == "hooks" else { return nil }
            guard assignment.key == ["hooks"] else { throw CodexTOMLLineScanner.Failure.ambiguous }
            return (line, assignment.valueStart)
        }
        guard assignments.count <= 1 else { throw CodexTOMLLineScanner.Failure.ambiguous }
        if let (line, start) = assignments.first {
            let value = CodexTOMLLineScanner.text(scanner.mask[start..<line.range.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "true" { return (contents, .alreadyEnabled) }
            guard value == "false" else { throw CodexTOMLLineScanner.Failure.ambiguous }
            let original = CodexTOMLLineScanner.text(scanner.bytes[start..<line.range.upperBound])
            let replacementStart = start + original.prefix(while: { $0 == " " || $0 == "\t" }).utf8.count
            return (
                CodexTOMLLineScanner.replacing(
                    contents, edits: [(replacementStart..<(replacementStart + 5), "true")]), .enabledInExistingTable
            )
        }
        let insertion = table.header.range.upperBound
        let prefix = insertion > 0 && scanner.bytes[insertion - 1] != 10 ? terminator : ""
        return (
            CodexTOMLLineScanner.replacing(
                contents, edits: [(insertion..<insertion, prefix + "hooks = true" + terminator)]),
            .enabledInExistingTable
        )
    }
}
