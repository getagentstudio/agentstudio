# EX2c: existing complete-snapshot component tests

Question: does ZMX's existing pinned VT dependency already contain an executable snapshot/continuation primitive worth investigating before adding another Host VT?

This is the bounded optional E1/R12 component arm, not EX2b's native relay and not a ZMX repair. No app, daemon or socket was started. No upstream/product source or fixture was changed.

## Target and deciding evidence

- Ghostty dependency pin: `8af6897c0afc63037a8a3efee4162a380e3a4572`, from the retained ZMX experiment checkout's `build.zig.zon`.
- Six decisive build/export/snapshot/continuation/fixture files were byte-compared to that Git object's blobs. All six match; hashes are in [result.json](../../../../../../../tmp/experiments/2026-10-20-zmx-latest/EX2c-snapshot-component/result.json).
- Compiler: existing mise Zig 0.16.0. Target from the upstream build: `aarch64-macos.13.0`, running on this Mac.
- Existing upstream `test-lib-vt` target, filter `complete snapshot`, lib-VT mode with macOS app and xcframework disabled. Caches are in `/private/tmp/2026-10-daemon-snapshot-probe/`, never the product's vendors/build output.
- Existing tests include a checked-in complete history/alternate-screen fixture, literal pending CSI continuation, changed suffix chunking, and every cut across finite UTF-8/CSI/OSC/DCS/APC/CAN/SUB corpora. These test bodies were opened; the passing group is not evidence for unenumerated terminal state or arbitrary future versions.

## Execution and correction

The first invocation used `--build-file` from the AgentStudio root. Compilation succeeded, but the complete-history/alternate-screen test failed in both roots with `FileNotFound` while opening a repository-relative golden fixture. Raw [run.log](../../../../../../../tmp/experiments/2026-10-20-zmx-latest/EX2c-snapshot-component/run.log) reports 87/89 executions passing and exit 1. This is an observation-setup failure, not a reproduced snapshot mismatch. The fixture/helper was inspected before correcting the working directory.

The corrected invocation ran from the upstream Ghostty package root, with the same code, fixtures, filter and target:

```sh
mise exec zig@0.16.0 -- zig build \
  --cache-dir /private/tmp/2026-10-daemon-snapshot-probe/local-cache \
  --global-cache-dir /private/tmp/2026-10-daemon-snapshot-probe/global-cache \
  -Demit-lib-vt=true -Demit-xcframework=false -Demit-macos-app=false \
  -Dtest-filter='complete snapshot' test-lib-vt --summary all
```

That exact command was run through the tool's working-directory field, not a source edit. [run-from-package-root.log](../../../../../../../tmp/experiments/2026-10-20-zmx-latest/EX2c-snapshot-component/run-from-package-root.log): **46/46 steps, 89/89 test executions, exit 0**. One root runs 44 tests, the other 45. Their coverage overlaps; this is not 89 independent behaviors or a second independent oracle.

The earlier mise environment query required its usual per-user trusted-config state access. The sandbox rejected that access; the exact environment query was then granted through the host permission tool. No Router/session/provider permissions were changed.

## Conclusion and remaining boundaries

The existing pinned component is a credible checkpoint implementation to investigate. These tests exercise complete state and explicitly configured parser-continuation custody; a formatted Capture payload is not that binary snapshot. The component result removes the basis for assuming an extra Host VT is automatically necessary.

It does not prove ZMX exports the checkpoint, that its live stream tracks the required continuation, that AgentStudio's embedded Ghostty surface can import it, that two VT pins interoperate, or that the binary format is stable. It establishes no safe Rust binding, actual network/UDS profile, Linux/iOS result, multi-view controller behavior or full user journey. A production design still needs those interfaces, resource/version/retention bounds and actual integration evidence. No alternative architecture or weaker restoration policy is selected.

No permanent test was added or changed. Build output remains isolated for inspection; experiment component processes completed through the build runner. This result is retained evidence, not project completion.
