import AgentStudioTestSupport
import CryptoKit
import Foundation

struct WorktreeCreationLargeFileFixture {
    let repository: URL
    let payload: Data
    let pointer: String

    static func create(named name: String, includeStoreObject: Bool) async throws -> Self {
        let repository = try await FilesystemTestGitRepo.create(named: name)
        let payload = Data("local LFS payload for \(name)\n".utf8)
        let objectID = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(objectID)\nsize \(payload.count)\n"
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(
            to: repository.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        try pointer.write(to: repository.appending(path: "asset.bin"), atomically: true, encoding: .utf8)
        _ = try await FilesystemTestGitRepo.runGit(at: repository, args: ["add", ".gitattributes", "asset.bin"])
        _ = try await FilesystemTestGitRepo.runGit(at: repository, args: ["commit", "-m", "commit LFS pointer"])

        let firstPrefix = String(objectID.prefix(2))
        let secondPrefix = String(objectID.dropFirst(2).prefix(2))
        let objectDirectory =
            repository
            .appending(path: ".git/lfs/objects")
            .appending(path: firstPrefix)
            .appending(path: secondPrefix)
        if includeStoreObject {
            try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
            try payload.write(to: objectDirectory.appending(path: objectID), options: .atomic)
        }
        return Self(repository: repository, payload: payload, pointer: pointer)
    }
}
