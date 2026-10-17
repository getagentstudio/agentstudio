import Foundation

/// Parses the `sysctl(CTL_KERN, KERN_PROCARGS2, pid)` buffer format, the
/// wire shape `ColdStartObserver`'s handoff check reads to find the startup
/// token in a process's argument vector (Program Design revision 11, item
/// 3, "the token"). Only the arguments are used -- macOS returns no
/// environment to a third-party reader for any process, so this parser
/// never looks past argv.
///
/// Layout, confirmed empirically against a live macOS process (a native
/// `Int32` argc, then the exec path, then argc argv strings, every string
/// NUL-terminated with NUL padding between sections; anything after argv,
/// including any environment section, is ignored):
///
/// ```
/// [argc: Int32][exec path\0][\0 padding][argv[0]\0]...[argv[argc-1]\0][...ignored]
/// ```
///
/// Bounds are never trusted implicitly: a truncated buffer or a missing
/// terminator ends parsing early rather than reading past the buffer, since
/// this reads memory the kernel filled for an external, unrelated process.
enum ProcessArgumentsBufferParser {
    /// Returns the process's argument vector (never the exec path itself),
    /// or `nil` when the buffer is malformed, truncated, or too short to
    /// contain `argc` argv strings -- matching `ColdStartUnobservableReason
    /// .processArgsUnreadable`'s "returned no argument vector" case.
    static func argumentVector(in buffer: [UInt8]) -> [String]? {
        guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
        let argumentCount = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        }
        guard argumentCount >= 0 else { return nil }
        var offset = MemoryLayout<Int32>.size
        guard let execPathEnd = nulTerminatedStringEnd(in: buffer, from: offset) else { return nil }
        offset = skipNULPadding(in: buffer, from: execPathEnd)

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0..<argumentCount {
            guard let argumentEnd = nulTerminatedStringEnd(in: buffer, from: offset) else { return nil }
            guard let argument = String(bytes: buffer[offset..<(argumentEnd - 1)], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            offset = argumentEnd
        }
        return arguments
    }

    /// The offset one past the first NUL at or after `start`, or `nil` when
    /// none is found before the buffer ends.
    private static func nulTerminatedStringEnd(in buffer: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < buffer.count {
            if buffer[index] == 0 { return index + 1 }
            index += 1
        }
        return nil
    }

    private static func skipNULPadding(in buffer: [UInt8], from start: Int) -> Int {
        var index = start
        while index < buffer.count, buffer[index] == 0 {
            index += 1
        }
        return index
    }
}
