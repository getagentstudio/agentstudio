import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Pure byte-domain rules. No decoding/re-encoding alters captured bytes.
enum ScrollbackPersistedForm {
    static let resetPrefix = ScrollbackReplayFrame.resetPrefix
    static let truncationMarker = Data("[older output omitted]\r\n".utf8)

    static func make(_ capture: Data, byteCap: Int) -> Data {
        let header = resetPrefix + truncationMarker
        precondition(byteCap >= header.count && byteCap <= AppPolicies.Restore.snapshotByteCap)
        if capture.count <= byteCap - resetPrefix.count {
            return resetPrefix + capture
        }
        let earliestOffset = capture.count - (byteCap - header.count)
        let cutOffset = capture.withUnsafeBytes { rawBytes in
            safeSuffixOffset(in: rawBytes.bindMemory(to: UInt8.self), atOrAfter: earliestOffset)
        }
        var persisted = header
        persisted.append(capture.suffix(capture.count - cutOffset))
        return persisted
    }

    /// Only a valid, incomplete trailing scalar is cut. Invalid interior,
    /// overlong and surrogate bytes remain for the shared validator to reject.
    static func trimmingIncompleteUTF8Suffix(_ capture: Data) -> Data {
        let offset = capture.withUnsafeBytes { rawBytes -> Int in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { return 0 }
            var start = bytes.count - 1
            while start > 0, bytes[start] & 0xC0 == 0x80, bytes.count - start <= 3 { start -= 1 }
            let width: Int
            switch bytes[start] {
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: return bytes.count
            }
            guard bytes.count - start < width else { return bytes.count }
            for index in (start + 1)..<bytes.count {
                guard bytes[index] & 0xC0 == 0x80 else { return bytes.count }
            }
            if start + 1 < bytes.count {
                let second = bytes[start + 1]
                switch bytes[start] {
                case 0xE0 where second < 0xA0, 0xED where second > 0x9F,
                    0xF0 where second < 0x90, 0xF4 where second > 0x8F:
                    return bytes.count
                default: break
                }
            }
            return start
        }
        return offset == capture.count ? capture : Data(capture.prefix(offset))
    }

    private enum ModeBlockDecodingError: Error { case invalidUTF8 }

    /// Policy for the serializer's leading mode block, not later replayed
    /// application text. One function owns the provisional keepPrevious choice.
    static func isAlternateScreenCapture(_ capture: Data) throws -> Bool {
        try capture.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var offset = 0
            var alternateScreen = false
            while offset + 1 < bytes.count, bytes[offset] == 0x1B {
                if bytes[offset + 1] == 0x63 {
                    alternateScreen = false
                    offset += 2
                    continue
                }
                if [0x28, 0x29, 0x2A, 0x2B].contains(bytes[offset + 1]), offset + 2 < bytes.count {
                    offset += 3
                    continue
                }
                guard bytes[offset + 1] == 0x5B else { break }
                let start = offset + 2
                var end = start
                while end < bytes.count, (0x20...0x3F).contains(bytes[end]) { end += 1 }
                guard end < bytes.count, (0x40...0x7E).contains(bytes[end]) else { break }
                if start < end, bytes[start] == 0x3F, bytes[end] == 0x68 || bytes[end] == 0x6C {
                    guard let parameters = String(bytes: bytes[(start + 1)..<end], encoding: .utf8) else {
                        throw ModeBlockDecodingError.invalidUTF8
                    }
                    let modes = parameters.split(separator: ";")
                    if modes.contains(where: { $0 == "1049" || $0 == "1047" || $0 == "47" }) {
                        alternateScreen = bytes[end] == 0x68
                    }
                }
                offset = end + 1
            }
            return alternateScreen
        }
    }

    /// Parse from the beginning: a local look-behind cannot distinguish
    /// ordinary text from the middle of a long OSC/DCS payload.
    private static func safeSuffixOffset(in bytes: UnsafeBufferPointer<UInt8>, atOrAfter minimum: Int) -> Int {
        var escapeState = EscapeBoundaryState.ground
        for offset in bytes.indices {
            let byte = bytes[offset]
            if offset >= minimum, escapeState == .ground, byte & 0xC0 != 0x80 {
                return offset
            }
            escapeState.consume(byte)
        }
        // An unterminated sequence crossing the cut has no safe suffix;
        // the bounded reset and omission marker are still replayable.
        return bytes.count
    }
}

private enum EscapeBoundaryState: Equatable {
    case ground
    case escape
    case escapeIntermediate
    case csi
    case controlString(osc: Bool)
    case controlStringEscape(osc: Bool)

    mutating func consume(_ byte: UInt8) {
        if byte == 0x18 || byte == 0x1A {
            self = .ground
            return
        }
        switch self {
        case .ground:
            if byte == 0x1B { self = .escape }
        case .escape:
            switch byte {
            case 0x1B: break
            case 0x5B: self = .csi
            case 0x5D: self = .controlString(osc: true)
            case 0x50, 0x58, 0x5E, 0x5F: self = .controlString(osc: false)
            case 0x20...0x2F: self = .escapeIntermediate
            case 0x30...0x7E: self = .ground
            default: break
            }
        case .escapeIntermediate:
            if byte == 0x1B { self = .escape } else if (0x30...0x7E).contains(byte) { self = .ground }
        case .csi:
            if byte == 0x1B { self = .escape } else if (0x40...0x7E).contains(byte) { self = .ground }
        case .controlString(let osc):
            if byte == 0x1B { self = .controlStringEscape(osc: osc) } else if osc && byte == 0x07 { self = .ground }
        case .controlStringEscape(let osc):
            if byte == 0x5C || (osc && byte == 0x07) {
                self = .ground
            } else if byte != 0x1B {
                self = .controlString(osc: osc)
            }
        }
    }
}
