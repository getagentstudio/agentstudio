import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

enum PullRequestCLI {
    static let usage =
        "pr add|remove PR (--target PANE_ID | --target-env)\n       agentstudio pr list (--target PANE_ID | --target-env)"
    enum Verb: String { case add, remove, list }
    struct Reference {
        let identity: IPCPanePullRequestIdentity
        let original: String
    }
    enum Operation {
        case add(Reference)
        case remove(Reference)
        case list

        var verb: Verb {
            switch self {
            case .add: .add
            case .remove: .remove
            case .list: .list
            }
        }
    }
    struct Request {
        let paneId: UUID
        let operation: Operation
    }
    enum Refusal: Error {
        case usage
        case target(PaneTargetFlags.Refusal)
        case reference(GitHubPullRequestReference.Refusal)

        var line: String {
            switch self {
            case .usage: "Usage: agentstudio \(PullRequestCLI.usage)"
            case .target(.targetFlags): "choose one of --target or --target-env"
            case .target(.missingEnvironment): "AGENTSTUDIO_PANE_ID is not set; use --target"
            case .target(.paneNotFound(let target)): "pane not found: \(target)"
            case .reference(let refusal): refusal.line
            }
        }

        var exitCode: Int32 {
            switch self {
            case .usage, .target(.targetFlags), .target(.missingEnvironment): 2
            case .target(.paneNotFound), .reference: 1
            }
        }
    }

    static func parse(_ arguments: [String], environment: [String: String]) throws -> Request {
        guard arguments.count >= 2, let verb = Verb(rawValue: arguments[1]) else {
            throw Refusal.usage
        }
        var rest = Array(arguments.dropFirst(2))
        var flags = PaneTargetFlags()
        var reference: String?
        while !rest.isEmpty {
            let argument = rest.removeFirst()
            do {
                if try flags.consume(argument, remaining: &rest) { continue }
            } catch { throw Refusal.target(error) }
            guard reference == nil, verb != .list else {
                throw Refusal.usage
            }
            reference = argument
        }
        let pane: UUID
        do { pane = try flags.resolve(environment: environment) } catch { throw Refusal.target(error) }
        if verb == .list { return .init(paneId: pane, operation: .list) }
        guard let reference else { throw Refusal.usage }
        do {
            let parsed = Reference(identity: try GitHubPullRequestReference.parse(reference), original: reference)
            switch verb {
            case .add: return .init(paneId: pane, operation: .add(parsed))
            case .remove: return .init(paneId: pane, operation: .remove(parsed))
            case .list: return .init(paneId: pane, operation: .list)
            }
        } catch { throw Refusal.reference(error) }
    }

    static func reference(_ identity: IPCPanePullRequestIdentity) -> String {
        "\(identity.owner)/\(identity.repository)#\(identity.number)"
    }

    static func line(_ row: IPCPanePullRequestListRow) -> String {
        var sources = row.isWorktree ? ["worktree"] : []
        sources += row.authors.map { author in
            switch author {
            case .paneAgent(let pane, let conversation): conversation?.provider ?? "an agent in \(pane.uuidString)"
            case .client: "an automation client"
            case .person: "You"
            }
        }
        return ([reference(row.identity), sources.joined(separator: ", ")] + (row.state.map { [$0.rawValue] } ?? []))
            .joined(separator: " · ")
    }
}

struct PullRequestCLIRunner: Sendable {
    let props: AgentStudioIPCClientCommandLineRunner.Props
    let global: IPCClientGlobalArguments
    let deadline: CallDeadline

    func run() throws -> Int32 {
        let request: PullRequestCLI.Request
        do { request = try PullRequestCLI.parse(global.methodArguments, environment: props.environment) } catch let
            refusal as PullRequestCLI.Refusal
        {
            props.standardErrorSink(refusal.line)
            return refusal.exitCode
        }
        guard global.configuration.authToken != nil else {
            props.standardErrorSink("Agent Studio refused the call: no credential")
            return 1
        }
        let method = "pane.pullRequest.\(request.operation.verb.rawValue)"
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: props.identifierGenerator()))
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: [method], authenticated: true, inputs: inputs)
        guard let descriptor = descriptors.first(where: { $0.metadata.name == method }) else {
            throw IPCMethodDescriptorRepresentationLookupError.missingMethod(method)
        }
        let parameters: Data
        switch request.operation {
        case .list:
            parameters = try JSONEncoder().encode(
                IPCPanePullRequestListParams(targetPaneHandle: request.paneId.uuidString))
        case .add(let reference), .remove(let reference):
            parameters = try JSONEncoder().encode(
                IPCPanePullRequestMutationParams(
                    targetPaneHandle: request.paneId.uuidString, pullRequest: reference.identity,
                    writer: PaneCLICommandRunner.writerClaim(environment: props.environment),
                    correlationId: props.identifierGenerator()))
        }
        let invocation = try IPCDescriptorInvocation(
            descriptor: descriptor, normalizedParameters: descriptor.normalizeParameters(parameters),
            presentation: .tooling)
        let client = AgentStudioIPCClient(
            configuration: global.configuration, descriptors: descriptors, deadline: deadline,
            onCallCompletion: { _ in })
        let result: IPCDescriptorClientCallResult
        do { result = try client.call(invocation) } catch is IPCDescriptorClientFailure {
            props.standardErrorSink("Agent Studio is not reachable")
            return 1
        }
        switch result {
        case .success(let response): return try success(response.normalizedResult.data, request: request)
        case .remoteFailure(let failure):
            guard let line = refusalLine(failure, request: request) else { throw failure }
            props.standardErrorSink(line)
            return 1
        }
    }

    private func success(_ data: Data, request: PullRequestCLI.Request) throws -> Int32 {
        switch request.operation {
        case .list:
            let rows = try JSONDecoder().decode(IPCPanePullRequestListResult.self, from: data).rows
            if rows.isEmpty { props.standardOutputSink("no pull requests on this pane") }
            for row in rows { props.standardOutputSink(PullRequestCLI.line(row)) }
            return 0
        case .add(let input):
            let reference = PullRequestCLI.reference(input.identity)
            switch try JSONDecoder().decode(IPCPanePullRequestAddResult.self, from: data) {
            case .added: props.standardOutputSink("added \(reference) to the pane")
            case .alreadyPresent: props.standardOutputSink("\(reference) is already on the pane")
            case .paneFull:
                props.standardErrorSink("the pane already has 20 pull requests")
                return 1
            }
            return 0
        case .remove(let input):
            let reference = PullRequestCLI.reference(input.identity)
            switch try JSONDecoder().decode(IPCPanePullRequestRemoveResult.self, from: data) {
            case .removed: props.standardOutputSink("removed \(reference) from the pane")
            case .notOnPane: props.standardOutputSink("\(reference) is not on this pane")
            case .addedBySomeoneElse:
                props.standardErrorSink("\(reference) was added by someone else; not removed")
                return 1
            }
            return 0
        }
    }

    private func refusalLine(_ failure: IPCDescriptorRemoteFailure, request: PullRequestCLI.Request) -> String? {
        switch failure.documentedReason {
        case "notMainPane": "not a main pane: \(request.paneId.uuidString)"
        case "targetNotFound": "pane not found: \(request.paneId.uuidString)"
        case "noActiveWindow": "Agent Studio has no open window"
        case "notGitHub":
            switch request.operation {
            case .add(let reference), .remove(let reference): "not a GitHub pull request: \(reference.original)"
            case .list: nil
            }
        case "unavailable": "Agent Studio refused the call: storage unavailable"
        case nil where failure.code == -32_004: "pane not found: \(request.paneId.uuidString)"
        case nil where failure.code == -32_006: "Agent Studio has no open window"
        case nil where failure.code == -32_001: "Agent Studio refused the call: no credential"
        default: nil
        }
    }
}
