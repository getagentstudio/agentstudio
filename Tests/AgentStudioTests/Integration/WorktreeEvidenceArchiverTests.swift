import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree removal evidence archiver")
struct WorktreeEvidenceArchiverTests {
    @Test("archives nested evidence and preserves a symlink without copying its target")
    func archivesFilesAndSymlinks() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.destroy() }
        let source = fixture.worktree.appending(path: "tmp", directoryHint: .isDirectory)
        let nestedSource = source.appending(path: "nested", directoryHint: .isDirectory)
        let destination = fixture.archiveRoot.appending(path: "repo.feature", directoryHint: .isDirectory)
        let sourceFile = nestedSource.appending(path: "note.txt")
        let externalFile = fixture.externalRoot.appending(path: "outside.txt")

        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.archiveRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.externalRoot, withIntermediateDirectories: true)
        try Data("preserve this".utf8).write(to: sourceFile)
        try Data("outside".utf8).write(to: externalFile)
        let sourceLink = source.appending(path: "external-link")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: externalFile)

        let result = WorktreeEvidenceArchiver().archive(source: source, destination: destination)

        #expect(result == .archived(path: destination, fileCount: 2))
        #expect(try Data(contentsOf: destination.appending(path: "nested/note.txt")) == Data("preserve this".utf8))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "external-link").path)
                == externalFile.path)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "outside.txt").path) == false)
    }

    @Test("a destination that appears before copy is left untouched")
    func keepsAnExistingDestination() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.destroy() }
        let source = fixture.worktree.appending(path: "tmp", directoryHint: .isDirectory)
        let destination = fixture.archiveRoot.appending(path: "repo.feature", directoryHint: .isDirectory)
        let existingFile = destination.appending(path: "keep.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: existingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appending(path: "note.txt"))
        try Data("keep".utf8).write(to: existingFile)

        let result = WorktreeEvidenceArchiver().archive(source: source, destination: destination)

        #expect(result == .partialCopy(path: destination))
        #expect(try Data(contentsOf: existingFile) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "note.txt").path) == false)
    }
}

private struct ArchiveFixture {
    let root: URL
    let worktree: URL
    let archiveRoot: URL
    let externalRoot: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "worktree-archive-\(UUIDv7.generate().uuidString)")
        let worktree = root.appending(path: "repo.feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        return Self(
            root: root,
            worktree: worktree,
            archiveRoot: root.appending(path: "archive", directoryHint: .isDirectory),
            externalRoot: root.appending(path: "outside", directoryHint: .isDirectory)
        )
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}
