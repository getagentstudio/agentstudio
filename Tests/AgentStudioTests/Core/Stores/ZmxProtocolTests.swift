import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Bundled zmx protocol")
struct ZmxProtocolTests {
    @Test("the control client's protocol matches the bundled daemon")
    func bundledProtocolMatchesControlClient() async throws {
        // The independent oracle is the vendor's declaration, not an app fixture.
        let source = try await pinnedSource(in: URL(filePath: FileManager.default.currentDirectoryPath))
        #expect(ZmxProtocol.version == (try protocolVersion(in: source)))
    }

    @Test("a shared consumer reads its pinned protocol without a vendor checkout and refuses missing objects")
    func unhydratedConsumerUsesPinnedSource() async throws {
        let repository = URL(filePath: FileManager.default.currentDirectoryPath)
        let fixture = FileManager.default.temporaryDirectory.appending(path: "zmx-pin-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let primary = fixture.appending(path: "primary")
        let consumer = fixture.appending(path: "consumer")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        _ = try await git(["clone", "--shared", "--no-checkout", repository.path, primary.path], in: repository)
        _ = try await git(["worktree", "add", "--detach", "--no-checkout", consumer.path, "HEAD"], in: primary)
        let module = try await pinnedSourceObject(in: repository).module
        let fixtureModule = primary.appending(path: ".git/modules/vendor/zmx")
        try FileManager.default.createDirectory(
            at: fixtureModule.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Shared setup supplies outputs, never source. Only the primary module's object database is available.
        #expect(!FileManager.default.fileExists(atPath: consumer.appending(path: "vendor/zmx/src/ipc.zig").path))
        do {
            _ = try await pinnedSource(in: consumer)
            Issue.record("Missing module objects must fail the mandatory protocol comparison")
        } catch {
            #expect(error.localizedDescription.contains("Missing pinned zmx source object"))
        }
        try FileManager.default.createSymbolicLink(atPath: fixtureModule.path, withDestinationPath: module)
        #expect(ZmxProtocol.version == (try protocolVersion(in: await pinnedSource(in: consumer))))
    }

    private func pinnedSource(in repository: URL) async throws -> String {
        try await pinnedSourceObject(in: repository).source
    }

    private func pinnedSourceObject(in repository: URL) async throws -> (source: String, module: String) {
        let entry = try await git(["ls-tree", "HEAD", "vendor/zmx"], in: repository).split(
            whereSeparator: \.isWhitespace)
        let revision = try #require(
            entry.count == 4 && entry[0] == "160000" ? String(entry[2]) : nil,
            "HEAD must pin vendor/zmx as a gitlink")
        let localModule = try await git(
            ["rev-parse", "--path-format=absolute", "--git-path", "modules/vendor/zmx"], in: repository)
        let commonDirectory = try await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repository)
        let sharedModule = URL(filePath: commonDirectory).appending(path: "modules/vendor/zmx").path
        var failures: [String] = []
        for module in Set([localModule, sharedModule]).sorted() {
            let result = try await runCommandToExit(
                command: "git", arguments: ["--git-dir=\(module)", "show", "\(revision):src/ipc.zig"],
                currentDirectoryURL: repository)
            if result.succeeded { return (result.stdout, module) }
            failures.append("\(module): \(result.stderr)")
        }
        throw NSError(
            domain: "PinnedZmxSource", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Missing pinned zmx source object \(revision):src/ipc.zig. Prepare matching vendor inputs. \(failures.joined(separator: "; "))"
            ])
    }

    private func git(_ arguments: [String], in repository: URL) async throws -> String {
        let result = try await runCommandToExit(command: "git", arguments: arguments, currentDirectoryURL: repository)
        guard result.succeeded else {
            throw NSError(
                domain: "PinnedZmxSource", code: result.exitCode,
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(result.stderr)"])
        }
        return result.stdout
    }

    private func protocolVersion(in source: String) throws -> UInt8 {
        let declaration = try #require(
            source.split(separator: "\n").first { $0.hasPrefix("pub const PROTOCOL_VERSION: u8 = ") })
        let literal = try #require(declaration.split(separator: "=").last)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let vendorVersion = try #require(UInt8(literal))

        return vendorVersion
    }
}
