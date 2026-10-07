import Foundation
import Testing

@testable import AgentStudioCore

/// Program Design revision 11, item 3, "the token": `ColdStartObserver`'s
/// handoff check reads this exact `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`
/// wire format for the process's argument vector -- never the environment.
/// These synthetic buffers match the layout confirmed empirically against a
/// live macOS process (`argc`, then the exec path, then argc argv strings,
/// each NUL-terminated with NUL padding between sections) -- this suite
/// proves the parser against that shape without needing a real process.
@Suite("Process arguments buffer parser")
struct ProcessArgumentsBufferParserTests {
    @Test("returns the argument vector, never including the exec path itself")
    func returnsTheArgumentVectorWithoutTheExecPath() {
        let buffer = makeBuffer(execPath: "/bin/sh", argv: ["-c", "the script", "agentstudio-restore-abc-123"])

        let arguments = ProcessArgumentsBufferParser.argumentVector(in: buffer)

        #expect(arguments == ["-c", "the script", "agentstudio-restore-abc-123"])
    }

    @Test("an empty argument vector (argc = 0) returns an empty array, not nil")
    func emptyArgumentVectorReturnsEmptyArray() {
        let buffer = makeBuffer(execPath: "/bin/sh", argv: [])

        let arguments = ProcessArgumentsBufferParser.argumentVector(in: buffer)

        #expect(arguments?.isEmpty == true)
    }

    @Test("a buffer shorter than the argc field returns nil, never crashes")
    func tooShortForArgcReturnsNil() {
        let buffer: [UInt8] = [0, 0]

        #expect(ProcessArgumentsBufferParser.argumentVector(in: buffer) == nil)
    }

    @Test("argc claiming more argv strings than the buffer actually holds returns nil, never reads out of bounds")
    func truncatedArgvReturnsNil() {
        // argc = 5, but only the exec path follows -- no argv strings, no
        // terminator for a 5th argument the buffer never contains.
        var buffer = withUnsafeBytes(of: Int32(5).littleEndian) { Array($0) }
        buffer.append(contentsOf: Array("/bin/sh".utf8))
        buffer.append(0)

        #expect(ProcessArgumentsBufferParser.argumentVector(in: buffer) == nil)
    }

    @Test("a negative argc is rejected rather than looping forever or reading out of bounds")
    func negativeArgcReturnsNil() {
        var buffer = withUnsafeBytes(of: Int32(-1).littleEndian) { Array($0) }
        buffer.append(contentsOf: Array("/bin/sh\0".utf8))

        #expect(ProcessArgumentsBufferParser.argumentVector(in: buffer) == nil)
    }

    @Test("multiple NUL padding bytes between the exec path and argv are skipped correctly")
    func multipleNULPaddingBytesAreSkipped() {
        var buffer = withUnsafeBytes(of: Int32(1).littleEndian) { Array($0) }
        buffer.append(contentsOf: Array("/bin/zsh\0".utf8))
        buffer.append(contentsOf: [0, 0, 0, 0, 0])  // extra alignment padding, as observed live
        buffer.append(contentsOf: Array("-zsh\0".utf8))

        let arguments = ProcessArgumentsBufferParser.argumentVector(in: buffer)

        #expect(arguments == ["-zsh"])
    }

    @Test("content after argv (an environment section, if any) is never included")
    func contentAfterArgvIsNeverIncluded() {
        var buffer = makeBuffer(execPath: "/bin/sh", argv: ["-c", "script"])
        buffer.append(0)
        buffer.append(contentsOf: Array("PATH=/usr/bin\0".utf8))

        let arguments = ProcessArgumentsBufferParser.argumentVector(in: buffer)

        #expect(arguments == ["-c", "script"])
    }

    // MARK: - Helpers

    /// Builds a synthetic `KERN_PROCARGS2` buffer: argc, exec path (NUL
    /// then one padding NUL), then argv strings (NUL-terminated).
    private func makeBuffer(execPath: String, argv: [String]) -> [UInt8] {
        var buffer = withUnsafeBytes(of: Int32(argv.count).littleEndian) { Array($0) }
        buffer.append(contentsOf: Array(execPath.utf8))
        buffer.append(0)
        buffer.append(0)  // alignment padding after the exec path, as observed live
        for argument in argv {
            buffer.append(contentsOf: Array(argument.utf8))
            buffer.append(0)
        }
        return buffer
    }
}
