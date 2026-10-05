import AgentStudioProgrammaticControl

/// Selects compiled recipes at the CLI boundary; the index is the real production default.
package struct IPCCompiledInvocationResolver: Sendable {
    private let index: IPCBuiltInMethodIndex

    package init(index: IPCBuiltInMethodIndex = IPCBuiltInMethodIndex()) {
        self.index = index
    }

    package func resolve(
        arguments: [String], authenticated: Bool, inputs: IPCBuiltInMethodCatalogInputs
    ) throws -> [IPCAnyMethodDescriptor] {
        if arguments.first == "command.execute" {
            let authentication =
                authenticated
                ? try resolve(arguments: ["auth.login"], authenticated: false, inputs: inputs) : []
            let execution = try IPCAnyMethodDescriptor(erasing: IPCCommandMethodComposition.compiledExecute())
            return authentication + [execution]
        }
        let selected = try selectedEntry(arguments: arguments)
        var requiredEntries = [selected]
        if authenticated, selected.name != "auth.login" {
            guard let authentication = index.entry(named: "auth.login") else {
                throw IPCMethodDescriptorRepresentationLookupError.missingMethod("auth.login")
            }
            requiredEntries.insert(authentication, at: 0)
        }
        return try requiredEntries.map { try $0.makeRepresentation(inputs: inputs).erasedDescriptor }
    }

    package func localHelp(
        arguments: [String], inputs: IPCBuiltInMethodCatalogInputs? = nil
    ) throws -> String? {
        try IPCDescriptorCLIHelp.localHelp(arguments: arguments, index: index, inputs: inputs)
    }

    private func selectedEntry(arguments: [String]) throws -> IPCBuiltInMethodIndexEntry {
        guard let name = arguments.first else {
            throw IPCDescriptorInvocationError.unknownMethod(named: "", index: index)
        }
        if let exact = index.entry(named: name) { return exact }
        let candidates = index.entries.flatMap { entry in
            entry.modelCalls.compactMap { projection -> (IPCBuiltInMethodIndexEntry, Int)? in
                let prefix = projection.variant.rawValue.split(separator: " ").map(String.init)
                return arguments.starts(with: prefix) ? (entry, prefix.count) : nil
            }
        }
        guard let longest = candidates.map({ $0.1 }).max() else {
            throw IPCDescriptorInvocationError.unknownMethod(named: name, index: index)
        }
        let matches = candidates.filter { $0.1 == longest }
        guard matches.count == 1, let candidate = matches.first else {
            throw IPCDescriptorInvocationError(
                reason: .ambiguousInvocation, fieldPath: "$", expected: "one descriptor model projection")
        }
        return candidate.0
    }

}
