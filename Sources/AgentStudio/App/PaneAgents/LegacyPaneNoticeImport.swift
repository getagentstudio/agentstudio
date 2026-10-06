import Foundation

/// First-start import only. No app or CLI writes NDJSON after the cutover.
enum LegacyPaneNoticeImport {
    struct LegacyFile: Sendable {
        let url: URL
        let paneID: UUID
        let payloads: [String]
        let malformedLineCount: Int
    }

    @concurrent nonisolated static func readFiles(in directory: URL, maximumPayloadBytes: Int) async -> [LegacyFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let suffix = ".notifications.ndjson"
        var files: [LegacyFile] = []
        for name in names.sorted() where name.hasSuffix(suffix) {
            guard let paneID = UUID(uuidString: String(name.dropLast(suffix.count))) else { continue }
            let url = directory.appending(path: name)
            guard let contents = try? Data(contentsOf: url) else { continue }
            var malformed = 0
            var payloads: [String] = []
            let lines = contents.split(separator: 0x0a, omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                guard !line.isEmpty else { continue }
                guard index < lines.count - 1 else {
                    malformed += 1
                    continue
                }
                let normalized = line.last == 0x0d ? line.dropLast() : line
                guard normalized.count <= maximumPayloadBytes,
                    let payload = String(bytes: normalized, encoding: .utf8)
                else {
                    malformed += 1
                    continue
                }
                payloads.append(payload)
            }
            files.append(LegacyFile(url: url, paneID: paneID, payloads: payloads, malformedLineCount: malformed))
        }
        return files
    }

    @concurrent nonisolated static func removeConsumedFile(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}
