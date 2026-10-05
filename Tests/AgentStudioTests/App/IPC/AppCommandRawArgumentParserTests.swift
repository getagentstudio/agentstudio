import AgentStudio
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App command raw argument parser")
struct AppCommandRawArgumentParserTests {
    @Test(
        "every compiled command argument variant is expressible with raw scalar strings",
        arguments: IPCCommandArgumentVariant.allCases)
    func everyVariantHasRawRepresentation(variant: IPCCommandArgumentVariant) throws {
        let raw = try rawExample(for: variant)
        let parsed = try AppCommandRawArgumentParser.parse(arguments: raw, allowedVariants: [variant])
        let expected = try variant.schema.decode(
            IPCCommandArguments.self,
            from: JSONEncoder().encode(raw.merging(["kind": variant.rawValue]) { _, right in right }))

        #expect(parsed == expected)
        #expect(parsed.variant == variant)
    }

    @Test("variant inference honors an explicit kind and preserves spaces and equals signs")
    func explicitKindAndStringContentsArePreserved() throws {
        let windowId = UUIDv7.generate()
        let raw = [
            "kind": "floatingTerminal", "workspaceWindowId": windowId.uuidString, "title": "name = other name",
            "launchDirectory": "/tmp/path with spaces",
        ]
        let parsed = try AppCommandRawArgumentParser.parse(
            arguments: raw, allowedVariants: [.floatingTerminal, .workspaceWindow])

        #expect(
            parsed
                == .floatingTerminal(
                    .init(
                        workspaceWindowId: windowId, launchDirectory: "/tmp/path with spaces",
                        title: "name = other name")))
    }

    @Test("optional values use the same descriptor defaults as typed command arguments")
    func omittedValuesUseDeclaredDefaults() throws {
        let windowId = UUIDv7.generate()
        let parsed = try AppCommandRawArgumentParser.parse(
            arguments: ["workspaceWindowId": windowId.uuidString], allowedVariants: [.webview])

        #expect(parsed == .webview(.init(workspaceWindowId: windowId, url: "https://github.com")))
    }

    @Test("ambiguous admitted variants require kind instead of guessing")
    func ambiguousVariantRequiresKind() {
        let failure = argumentFailure(
            arguments: ["workspaceWindowId": UUIDv7.generate().uuidString],
            variants: [.workspaceWindow, .floatingTerminal])

        #expect(failure?.fieldPath == "$.arguments.kind")
        #expect(failure?.expected.contains("workspaceWindow") == true)
        #expect(failure?.expected.contains("floatingTerminal") == true)
    }

    @Test("an explicit undeclared kind is refused")
    func undeclaredKindIsRefused() {
        let failure = argumentFailure(arguments: ["kind": "noArguments"], variants: [.repository])
        #expect(failure?.fieldPath == "$.arguments.kind")
        #expect(failure?.expected.contains("repository") == true)
    }

    @Test(
        "invalid UUID missing field and unknown field retain a concrete correction",
        arguments: ["invalid", "missing", "unknown"])
    func invalidValuesGiveFieldCorrection(scenario: String) {
        let raw: [String: String]
        let expectedField: String
        switch scenario {
        case "invalid":
            raw = ["repoId": "not-a-uuid"]
            expectedField = "repoId"
        case "missing":
            raw = [:]
            expectedField = "repoId"
        default:
            raw = ["repoId": UUIDv7.generate().uuidString, "surprise": "value"]
            expectedField = "surprise"
        }
        let failure = argumentFailure(arguments: raw, variants: [.repository])
        #expect(failure?.fieldPath == "$.arguments.\(expectedField)")
        #expect(failure?.expected.isEmpty == false)
    }

    private func argumentFailure(arguments: [String: String], variants: [IPCCommandArgumentVariant])
        -> IPCSchemaValidationError?
    {
        do {
            _ = try AppCommandRawArgumentParser.parse(arguments: arguments, allowedVariants: variants)
            return nil
        } catch { return error }
    }

    private func rawExample(for variant: IPCCommandArgumentVariant) throws -> [String: String] {
        guard case .object(let fields) = try variant.schema else {
            Issue.record("Command variant must remain a scalar object")
            return [:]
        }
        var raw: [String: String] = [:]
        for field in fields where field.name != "kind" {
            guard hasRawStringRepresentation(field.schema) else {
                Issue.record("Command argument requires a new key=value encoding: \(variant.rawValue).\(field.name)")
                continue
            }
            if field.name.hasSuffix("Id") {
                raw[field.name] = UUIDv7.generate().uuidString
            } else if field.name.contains("Selector") {
                raw[field.name] = "self"
            } else if field.name == "url" {
                raw[field.name] = "https://example.com/path?key=value"
            } else {
                raw[field.name] = "text with spaces = value"
            }
        }
        return raw
    }

    private func hasRawStringRepresentation(_ schema: IPCJSONSchema) -> Bool {
        switch schema {
        case .string:
            return true
        case .oneOf(let alternatives):
            return alternatives.count == 2 && alternatives.contains(.null)
                && alternatives.contains { alternative in
                    if case .string = alternative { return true }
                    return false
                }
        default:
            return false
        }
    }
}
