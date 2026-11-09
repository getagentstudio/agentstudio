import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

/// `agentstudio drawer browse <page> (--target <pane id> | --target-env)`.
/// Parses at the CLI boundary, calls `drawer.browse` once, and prints one line.
enum DrawerBrowseCLI {
    static let environmentPaneVariable = "AGENTSTUDIO_PANE_ID"
    static let usage = "drawer browse PAGE (--target PANE_ID | --target-env)"

    static func isInvocation(_ arguments: [String]) -> Bool {
        arguments.count >= 2 && arguments[0] == "drawer" && arguments[1] == "browse"
    }

    struct Request: Equatable {
        let page: IPCDrawerBrowserPage
        let parentPaneId: UUID
    }

    /// A refusal decided before or after the call; each has one output line.
    enum Refusal: Error, Equatable {
        case targetFlags
        case missingEnvironment
        case unsupportedPage
        case fileNotFound(path: String)
        case paneNotFound(String)
        case notMainPane(String)
        case noOpenWindow
        case unreachable

        var line: String {
            switch self {
            case .targetFlags: "choose one of --target or --target-env"
            case .missingEnvironment: "\(DrawerBrowseCLI.environmentPaneVariable) is not set; use --target"
            case .unsupportedPage: "not supported: only HTML files and URLs"
            case .fileNotFound(let path): "not found: \(path)"
            case .paneNotFound(let id): "pane not found: \(id)"
            case .notMainPane(let id): "not a main pane: \(id)"
            case .noOpenWindow: "Agent Studio has no open window"
            case .unreachable: "Agent Studio is not reachable"
            }
        }
    }

    /// Reads the page and exactly one target flag. A page with an http or https
    /// scheme is a web page; anything else is a path, made absolute against
    /// `currentDirectory`, which must be an existing `.html` or `.htm` file.
    static func parse(
        _ arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        isRegularFile: (String) -> Bool = { path in
            // Only a regular file is a page; a directory, pipe or socket isn't.
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    ) throws(Refusal) -> Request {
        var rest = Array(arguments.dropFirst(2))
        var target: String?
        var usesEnvironment = false
        var targetFlagCount = 0
        var pageArgument: String?
        while !rest.isEmpty {
            let argument = rest.removeFirst()
            switch argument {
            case "--target":
                targetFlagCount += 1
                guard !rest.isEmpty else { throw .targetFlags }
                target = rest.removeFirst()
            case "--target-env":
                targetFlagCount += 1
                usesEnvironment = true
            default:
                guard pageArgument == nil else { throw .unsupportedPage }
                pageArgument = argument
            }
        }
        guard targetFlagCount == 1 else { throw .targetFlags }
        if usesEnvironment {
            guard let value = environment[environmentPaneVariable], !value.isEmpty else { throw .missingEnvironment }
            target = value
        }
        guard let target, let parentPaneId = UUID(uuidString: target) else {
            throw .paneNotFound(target ?? "")
        }
        guard let pageArgument else { throw .unsupportedPage }
        return Request(
            page: try page(pageArgument, currentDirectory: currentDirectory, isRegularFile: isRegularFile),
            parentPaneId: parentPaneId)
    }

    private static func page(
        _ argument: String, currentDirectory: URL, isRegularFile: (String) -> Bool
    ) throws(Refusal) -> IPCDrawerBrowserPage {
        if let url = URL(string: argument), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            guard scheme == "http" || scheme == "https", url.host()?.isEmpty == false else { throw .unsupportedPage }
            return .web(url: argument)
        }
        let joined =
            argument.hasPrefix("/") ? URL(fileURLWithPath: argument) : currentDirectory.appending(path: argument)
        let absolute = joined.standardizedFileURL.path(percentEncoded: false)
        let pathExtension = (absolute as NSString).pathExtension.lowercased()
        guard pathExtension == "html" || pathExtension == "htm" else { throw .unsupportedPage }
        guard isRegularFile(absolute) else { throw .fileNotFound(path: absolute) }
        return .localHTML(path: absolute)
    }

    /// The success line for a completed open.
    static func line(for result: IPCDrawerBrowseResult) -> String {
        let landed =
            switch result.tab {
            case .newBrowser: "opened in a new drawer browser"
            case .newTab: "opened in a new browser tab"
            case .reusedTab: "reused the open browser tab"
            }
        let notice =
            switch result.notice {
            case .posted: "notice posted"
            case .failed: "notice failed"
            }
        return "\(landed); \(notice)"
    }

    /// The app's "target not found" code. It arrives without a reason, and a
    /// missing file shares it but always carries `fileNotFound`.
    private static let targetNotFoundCode = -32_004
    /// The app's "no active window" code, which arrives without a reason.
    private static let noActiveWindowCode = -32_006

    /// The refusal a remote failure stands for.
    static func refusal(for failure: IPCDescriptorRemoteFailure, request: Request) -> Refusal? {
        switch failure.documentedReason {
        case "unsupportedPage": return .unsupportedPage
        case "fileNotFound":
            if case .localHTML(let path) = request.page { return .fileNotFound(path: path) }
            return .unsupportedPage
        case "targetNotFound": return .paneNotFound(request.parentPaneId.uuidString)
        case "notMainPane": return .notMainPane(request.parentPaneId.uuidString)
        case nil where failure.code == targetNotFoundCode: return .paneNotFound(request.parentPaneId.uuidString)
        case nil where failure.code == noActiveWindowCode: return .noOpenWindow
        default: return nil
        }
    }
}

/// Runs one `drawer browse` call and prints its single line.
struct DrawerBrowseCLIRunner: Sendable {
    let props: AgentStudioIPCClientCommandLineRunner.Props
    let global: IPCClientGlobalArguments
    let deadline: CallDeadline

    /// 0 when the page opened; 2 for a usage refusal; 1 for any other refusal.
    func run() throws -> Int32 {
        let request: DrawerBrowseCLI.Request
        do {
            request = try DrawerBrowseCLI.parse(
                global.methodArguments, environment: props.environment,
                currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        } catch {
            props.standardErrorSink(error.line)
            return error == .targetFlags || error == .missingEnvironment ? 2 : 1
        }
        return try call(request)
    }

    /// Sends one parsed request and prints the line its outcome stands for.
    func call(_ request: DrawerBrowseCLI.Request) throws -> Int32 {
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: props.identifierGenerator()))
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: ["drawer.browse"], authenticated: global.configuration.authToken != nil, inputs: inputs)
        guard let descriptor = descriptors.first(where: { $0.metadata.name == "drawer.browse" }) else {
            throw IPCMethodDescriptorRepresentationLookupError.missingMethod("drawer.browse")
        }
        let parameters = IPCDrawerBrowseParams(
            parentPaneHandle: request.parentPaneId.uuidString, page: request.page,
            correlationId: props.identifierGenerator())
        let invocation = try IPCDescriptorInvocation(
            descriptor: descriptor,
            normalizedParameters: descriptor.normalizeParameters(JSONEncoder().encode(parameters)),
            presentation: .tooling)
        let client = AgentStudioIPCClient(
            configuration: global.configuration, descriptors: descriptors, deadline: deadline,
            onCallCompletion: { _ in })
        let callResult: IPCDescriptorClientCallResult
        do {
            callResult = try client.call(invocation)
        } catch is IPCDescriptorClientFailure {
            props.standardErrorSink(DrawerBrowseCLI.Refusal.unreachable.line)
            return 1
        }
        switch callResult {
        case .success(let response):
            let result = try JSONDecoder().decode(IPCDrawerBrowseResult.self, from: response.normalizedResult.data)
            props.standardOutputSink(DrawerBrowseCLI.line(for: result))
            return 0
        case .remoteFailure(let failure):
            guard let refusal = DrawerBrowseCLI.refusal(for: failure, request: request) else { throw failure }
            props.standardErrorSink(refusal.line)
            return 1
        }
    }
}
