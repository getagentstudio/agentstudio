import Foundation

/// Shared VT framing for the snapshot writer and the cold-restore script.
package enum ScrollbackReplayFrame {
    package static let resetPrefix = Data("\u{1B}c".utf8)

    /// Save before resetting 1049 so a primary-screen restore returns to the same cursor.
    /// Restore every touched mode to Ghostty's defaults, including alternate-scroll enabled.
    /// Reset each alternate-mode bit independently; screen selection alone does not clear them.
    /// DECSTBM homes the cursor, so DECRC immediately restores it before SGR/charset reset.
    /// Pop eight clears Ghostty's eight-slot kitty flag stack, including its base entry.
    package static let normalization =
        "\u{1B}7\u{1B}[?1049l\u{1B}[?1047l\u{1B}[?47l\u{1B}[r\u{1B}8"
        + "\u{1B}[?7h\u{1B}[?1l\u{1B}[?25h"
        + "\u{1B}[?9l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l"
        + "\u{1B}[?1004l\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1007h\u{1B}[?1015l\u{1B}[?1016l"
        + "\u{1B}[<8u\u{1B}[0m\u{1B}(B\u{0F}"
}
