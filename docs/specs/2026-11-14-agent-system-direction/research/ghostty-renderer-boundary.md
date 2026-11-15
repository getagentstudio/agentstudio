# Ghostty: native renderer and standalone terminal state

**A stable `libghostty-vt` ABI does not make a Rex stream directly consumable by AgentStudio's current native Ghostty surface.** This is the main qualification gap beneath the proposed interchangeable terminal backends.

## Two APIs with different consumers

| Boundary | Inspected evidence | Meaning for AgentStudio |
| --- | --- | --- |
| Native application embedding | Bundled [ghostty.h](../../../../vendor/ghostty/include/ghostty.h#L1) identifies itself as the internal embedder API. Its [surface declarations](../../../../vendor/ghostty/include/ghostty.h#L1176) cover creation, lifecycle, keyboard/mouse input and text selection/readback. | No caller-supplied output feed or binary snapshot-import operation is exposed in that inspected surface declaration block. `ghostty_surface_text` is input, not rendering output injection. This is a bounded declaration result, not proof that every possible integration is impossible. |
| Current AgentStudio surface | [Surface initialization](../../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift#L356) passes the selected startup command into `ghostty_surface_new`. | The current integration lets Ghostty run an external attachment command and render its output. |
| Standalone VT library | [The 1.0 announcement](https://mitchellh.com/writing/libghostty-1-0) describes the released C ABI, native/mobile artifacts and WebAssembly distribution. | Supplies terminal emulation and state APIs; it does not supply the complete AgentStudio native renderer, layout, focus, accessibility or input integration. |

The official [stability policy](https://lib.ghostty.org/vt/stability.html) expressly separates snapshot byte compatibility from the C ABI promise. The [snapshot guide](https://lib.ghostty.org/vt/guide-snapshots.html) returns a standalone terminal from its decoder and supports incremental restoration; it does not describe importing that terminal into a native `ghostty_surface_t`.

## The two restoration forms

ZMX's [serializer](../../../../vendor/zmx/src/terminal.zig#L132) emits styled VT reconstruction, including selected screen/mode metadata. It excludes transient synchronized-output replay and some state such as tab stops. Its [initialization handler](../../../../vendor/zmx/src/loop.zig#L977) queues that reconstruction as output before subsequent delivery on the attachment. This matches a terminal-consuming external attachment process, subject to runtime qualification of the complete handoff.

Herdrex's pinned [terminal-stream source](https://github.com/elonnzhang/Herdrex/blob/8bab18ef035a326ead3a93fc5afec159f1b2d88f/pkg/rex/termstream/termstream.go) embeds a blank Ghostty binary snapshot captured from Rex, then frames terminal output and nonce-qualified control messages. That is interoperability evidence for its tested producer/consumer pair, not a guarantee that any released VT decoder accepts that binary snapshot.

**Consequence:** restoration format, format version, screen/history coverage and live-output ordering cannot disappear inside an unlabelled byte buffer. The common contract can describe the outcome without forcing one backend's private snapshot format onto every client.

## Candidate routes and their costs

These are research candidates, not a selected Program Design.

| Candidate | What it could reuse | What still has to be proved or built |
| --- | --- | --- |
| External terminal attachment process | AgentStudio's current native surface and command-based attachment. | A Rex-compatible client/relay must handle handshake, snapshot decoding, a declared lossy restoration, live ordering, input, resize and disconnect. No such working bridge was demonstrated here. |
| Standalone VT plus a client renderer | Released state/render APIs and explicit control over incoming bytes. | Native drawing, input, selection, accessibility and platform integration become a separate frontend project. A shared emulator is not a shared finished renderer. |
| A newly supported upstream native embedding operation | Existing native surface if the required operation is actually supplied upstream. | No such operation was established in the inspected pin. This is not permission to maintain a Ghostty fork. |

One bounded hypothesis is decoding the initial Rex snapshot into a standalone VT terminal, formatting a one-time VT restoration, then continuing the live stream through a native attachment process. The library's [formatter documentation](https://lib.ghostty.org/vt/first-terminal.html#read-the-screen) supports exporting screen state as text/VT, but explicitly directs live rendering to render state. It does not establish complete snapshot-to-VT equivalence, preservation of unfinished parser input, history fidelity or the ordered transition to live bytes. Do not replace this hypothesis with continuous full-screen formatting or call it proven.

The cheapest deciding probe would use a pinned Rex producer and decoder, a known screen/history fixture, continued output produced during restoration, and the unforked native renderer. Compare the declared retained state and continuing input/output; include an unsupported or incompatible snapshot. Lossy acceptance still needs declared losses and a correct live handoff. No runtime probe ran in this research.

## Web renderer caution

The pinned [coder/ghostty-web build script](https://github.com/coder/ghostty-web/blob/640db4617c69a73ccebce437cebc598c7f73cdb7/scripts/build-wasm.sh) applies a patch to its Ghostty submodule, builds WASM, then reverses the patch in the checkout. Reversing it after the build does not make the resulting binary unpatched.

This does not establish that every future release requires the patch, or reject the library's usefulness. It means the inspected build is not evidence of satisfying AgentStudio's existing no-maintained-Ghostty-fork policy. A released unpatched artifact path needs its own source and integration check.

No renderer, mobile build, decoder compatibility, latency, memory bound or pixel-level result was observed. Public API availability and a stable C ABI are source facts, not a measured integration success.
