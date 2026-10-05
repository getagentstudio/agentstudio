import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation

/// Help projects compiled contracts before endpoint or credential resolution.
/// Live command identities are rendered only from an explicit discovery.
enum IPCDescriptorCLIHelp {
    static func localHelp(
        arguments: [String], index: IPCBuiltInMethodIndex, inputs: IPCBuiltInMethodCatalogInputs? = nil
    ) throws -> String? {
        if arguments == ["--help"] || arguments == ["help"] {
            return overview(index: index)
        }
        if arguments.count == 2, arguments[0] == "help", arguments[1] != "--live" {
            return try methodHelp(named: arguments[1], index: index, inputs: inputs)
        }
        if arguments.count == 2, arguments[1] == "--help" {
            return try methodHelp(named: arguments[0], index: index, inputs: inputs)
        }
        return nil
    }

    static func overview(index: IPCBuiltInMethodIndex) -> String {
        let staticMethods = index.entries.map {
            "  \($0.name) — \($0.summary)  [agent: \(agentLabel($0.agentEligibility))]"
        }
        let composedMethods = index.compositionHelp.map { projection in
            let access: String
            switch projection.agentAccess {
            case .readOnly: access = "read-only"
            case .selectedCommand: access = "conditional on selected command"
            }
            return "  \(projection.name) — \(projection.summary)  [agent: \(access)]"
        }
        let methods = (staticMethods + composedMethods).sorted()
        return
            ([
                "Usage: agentstudio [--socket PATH | --metadata PATH] [--token-stdin] METHOD [OPTIONS]",
                "       agentstudio METHOD --help",
                "       agentstudio help [--live]",
                "Methods:",
            ] + methods + [
                "Method help: agentstudio <method> --help",
                "Live commands: agentstudio help --live",
                "Use --json '{...}' or --stdin for a JSON parameter object.",
            ]).joined(separator: "\n")
    }

    static func liveCommands(_ commands: [IPCLiveCommandHelp.Command]) -> String {
        (["Live commands:"]
            + commands.sorted { $0.id < $1.id }.map {
                "  \($0.id) — \($0.title): \($0.description)"
            }).joined(separator: "\n")
    }

    private static func agentLabel(_ eligibility: IPCAgentEligibility?) -> String {
        switch eligibility {
        // Legacy nil methods retain the existing self-pane privilege baseline.
        case .ownPane, nil: "own pane"
        case .anyTarget: "read-only"
        case .notYetAllowed: "not yet allowed"
        }
    }

    private static func methodHelp(
        named name: String, index: IPCBuiltInMethodIndex, inputs: IPCBuiltInMethodCatalogInputs?
    ) throws -> String {
        guard let entry = index.entry(named: name) else {
            if let projection = index.compositionHelp.first(where: { $0.name == name }) {
                return try compositionMethodHelp(projection, inputs: inputs)
            }
            throw IPCDescriptorInvocationError.unknownMethod(named: name, index: index)
        }
        var lines = [
            "\(entry.name) — \(entry.summary)",
            "Usage: agentstudio \(entry.name) [OPTIONS | --json '{...}' | --stdin]",
        ]
        if case .object(let fields) = try entry.parameterSchema(), !fields.isEmpty {
            lines.append("Parameters:")
            for field in fields {
                let presence = field.presence == .required ? "required" : "optional"
                lines.append(
                    "  \(IPCDescriptorInvocationParser.toolingOptionName(for: field.name)) <value> (\(field.name), \(presence)) — \(field.description)"
                )
            }
        }
        for modelCall in entry.modelCalls {
            lines.append("Model invocation: agentstudio \(modelCall.variant.rawValue)")
        }
        if entry.correlationPolicy == .required {
            lines.append(
                "correlationId is generated when omitted and preserved when supplied, including JSON and stdin.")
        }
        lines.append("Use JSON or stdin for object and array parameters.")
        let exampleInputs = inputs ?? .init(examples: .init(illustrativeIdentifier: UUIDv7.generate()))
        let descriptor = try entry.makeRepresentation(inputs: exampleInputs).erasedDescriptor
        if let example = descriptor.metadata.examples.first {
            guard let parameterText = String(bytes: try example.encodedParameters(), encoding: .utf8) else {
                return lines.joined(separator: "\n")
            }
            let escapedParameterText = parameterText.replacingOccurrences(of: "'", with: "'\\''")
            lines.append("Example: agentstudio \(entry.name) --json '\(escapedParameterText)'")
        }
        return lines.joined(separator: "\n")
    }

    private static func compositionMethodHelp(
        _ projection: IPCMethodHelpProjection, inputs: IPCBuiltInMethodCatalogInputs?
    ) throws -> String {
        var lines = ["\(projection.name) — \(projection.summary)"]
        switch projection.argumentSyntax {
        case .rawCommandStrings:
            lines.append(
                "Usage: agentstudio \(projection.name) --command-id NAME "
                    + "[--arg key=value] [--correlation-id UUID]")
            lines.append("Agent eligibility is conditional on the selected command and its target.")
        case .schemaOptions:
            lines.append("Usage: agentstudio \(projection.name) [--json '{}' | --stdin]")
        }
        if case .object(let fields) = try projection.parameterSchema(), !fields.isEmpty {
            lines.append("Parameters:")
            for field in fields {
                let presence = field.presence == .required ? "required" : "optional"
                lines.append("  \(field.name) (\(presence)) — \(field.description)")
            }
        }
        let exampleInputs = inputs ?? .init(examples: .init(illustrativeIdentifier: UUIDv7.generate()))
        let arguments = projection.exampleArguments(inputs: exampleInputs).joined(separator: " ")
        lines.append("Example: agentstudio \(projection.name) \(arguments)")
        return lines.joined(separator: "\n")
    }
}
