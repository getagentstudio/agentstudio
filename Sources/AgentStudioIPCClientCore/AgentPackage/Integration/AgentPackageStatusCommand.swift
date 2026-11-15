import Foundation

package enum AgentPackageStatusSelection: Equatable, Sendable {
    case all
    case provider(AgentPackageTarget)
}

package struct AgentPackageStatusRequest: Equatable, Sendable {
    package let selection: AgentPackageStatusSelection
    package let json: Bool

    package init(selection: AgentPackageStatusSelection, json: Bool) {
        self.selection = selection
        self.json = json
    }
}

package enum AgentPackageStatusCommand {
    package static func run(
        request: AgentPackageStatusRequest, environment: [String: String], output: (String) -> Void,
        error errorSink: (String) -> Void
    ) -> Int32 {
        do {
            let targets: [AgentPackageTarget]
            switch request.selection {
            case .all: targets = AgentPackageProvider.allCases.map { .init(provider: $0, homePath: nil) }
            case .provider(let target): targets = [target]
            }
            let statuses = try targets.map { target in
                ProviderIntegrationInspector.inspect(
                    .init(layout: try .resolve(target: target, environment: environment), environment: environment))
            }
            output(
                try request.json
                    ? ProviderIntegrationStatusRenderer.json(statuses)
                    : ProviderIntegrationStatusRenderer.human(statuses))
            return statuses.allSatisfy { $0.verdict == .current } ? 0 : 1
        } catch {
            errorSink("agentstudio package status: \(error)")
            return 1
        }
    }
}
