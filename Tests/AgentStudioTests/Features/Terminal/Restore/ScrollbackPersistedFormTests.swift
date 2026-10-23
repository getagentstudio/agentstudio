import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

@Suite("Scrollback persisted form")
struct ScrollbackPersistedFormTests {
    @Test("persisted headers include a nonempty VT reset and readable truncation marker")
    func persistedHeadersHaveObservableContents() throws {
        #expect(ScrollbackStore.resetPrefix.count >= 2)
        #expect(ScrollbackStore.resetPrefix.first == 0x1B)
        let marker = try #require(String(data: ScrollbackStore.truncationMarker, encoding: .utf8))
        #expect(!marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("an untrimmed capture keeps all bytes after the reset prefix")
    func uncappedCapturePreservesBytes() {
        let capture = Data("  \t\u{1B}[31mcolored\u{1B}[0m\r\n".utf8)
        let persisted = ScrollbackStore.persistedForm(capture, byteCap: 256)
        #expect(persisted == ScrollbackStore.resetPrefix + capture)
    }

    @Test("generated Unicode inputs keep the largest newest scalar suffix within the complete cap", arguments: 0..<80)
    func generatedUnicodeInputsKeepNewestSafeSuffix(seed: Int) {
        let scalarTokens = ["a", "é", "🙂", "\u{301}", "中"]
        let scalarCount = 10 + seed * 7
        let text = (0..<scalarCount).map { scalarTokens[($0 * 3 + seed) % scalarTokens.count] }.joined()
        let capture = Data(text.utf8)
        let byteCap = 96 + seed % 31
        let persisted = ScrollbackStore.persistedForm(capture, byteCap: byteCap)
        #expect(persisted.count <= byteCap)
        #expect(persisted.starts(with: ScrollbackStore.resetPrefix))

        if capture.count + ScrollbackStore.resetPrefix.count <= byteCap {
            #expect(persisted == ScrollbackStore.resetPrefix + capture)
        } else {
            let header = ScrollbackStore.resetPrefix + ScrollbackStore.truncationMarker
            let expectedSuffix = newestScalarSuffix(text, byteBudget: byteCap - header.count)
            #expect(persisted == header + expectedSuffix)
            #expect(Data(capture.suffix(expectedSuffix.count)) == expectedSuffix)
            #expect(String(data: expectedSuffix, encoding: .utf8) != nil)
        }
    }

    @Test(
        "a long VT line is cut after a complete escape sequence",
        arguments: [
            "\u{1B}[123456789012345678901234567890m",
            "\u{1B}]0;long terminal title\u{7}",
            "\u{1B}]0;long terminal title\u{1B}\\",
            "\u{1B}Plong device control payload\u{1B}\\",
            "\u{1B}Xlong control string\u{1B}\\",
            "\u{1B}^long privacy message\u{1B}\\",
            "\u{1B}_long application command\u{1B}\\",
        ])
    func cutInsideEscapeKeepsOnlyNewestCompleteSuffix(escapeSequence: String) {
        let newest = Data("é🙂 newest".utf8)
        let capture = Data(String(repeating: "older ", count: 50).utf8) + Data(escapeSequence.utf8) + newest
        let header = ScrollbackStore.resetPrefix + ScrollbackStore.truncationMarker
        // The naive cut lands inside the final escape sequence. Its final
        // bytes cannot be replayed as ordinary text; the whole sequence ends
        // before the first safe retained scalar.
        let persisted = ScrollbackStore.persistedForm(capture, byteCap: header.count + newest.count + 3)
        #expect(persisted == header + newest)
    }

    @Test("a default snapshot includes reset and truncation marker within two MiB")
    func defaultCapCountsAllPersistedBytes() {
        let capture = Data(repeating: 0x78, count: AppPolicies.Restore.snapshotByteCap + 1024)
        let persisted = ScrollbackStore.persistedForm(capture)
        let header = ScrollbackStore.resetPrefix + ScrollbackStore.truncationMarker
        #expect(persisted.count == AppPolicies.Restore.snapshotByteCap)
        #expect(persisted.starts(with: header))
        #expect(Data(persisted.dropFirst(header.count)) == Data(capture.suffix(persisted.count - header.count)))
    }

    @Test("capping an ASCII multiline capture retains its newest bytes in order")
    func multilineCaptureKeepsNewestOutput() {
        let capture = Data((0..<100).map { "line \($0)\r\n" }.joined().utf8)
        let header = ScrollbackStore.resetPrefix + ScrollbackStore.truncationMarker
        let byteCap = header.count + 80
        let persisted = ScrollbackStore.persistedForm(capture, byteCap: byteCap)
        #expect(persisted == header + Data(capture.suffix(80)))
    }

    private func newestScalarSuffix(_ text: String, byteBudget: Int) -> Data {
        var suffix = Data()
        for scalar in text.unicodeScalars.reversed() {
            let scalarBytes = Data(String(scalar).utf8)
            guard suffix.count + scalarBytes.count <= byteBudget else { break }
            suffix = scalarBytes + suffix
        }
        return suffix
    }
}
