// Policy: tests should wait on application events or DOM conditions; suite bounds
// are intended to catch hangs, not decide correctness. Current debt: frozen
// timed-wait sites in architecture-debt-ledger.tsv are being retired. The unit
// and node-integration bounds remain 120 s (owner decision 2026-09-24); every
// other value remains the established bound for its suite.
export const unitTestTimeoutMilliseconds = 120_000;

// Vitest's own default hook bound, declared so unit teardown hooks have a named
// shared bound rather than an implicit library default.
export const unitHookTimeoutMilliseconds = 10_000;

export const nodeIntegrationTestTimeoutMilliseconds = 120_000;

export const browserIntegrationTestTimeoutMilliseconds = 60_000;

export const browserBenchmarkTestTimeoutMilliseconds = 15_000;

export const scriptBenchmarkTestTimeoutMilliseconds = 5_000;

// A real-backend journey on a 3-vCPU runner may legitimately be slow, so the
// E2E bound is wide; it still only stops a wedged run from hanging forever.
export const endToEndTestTimeoutMilliseconds = 600_000;

export const endToEndHookTimeoutMilliseconds = 60_000;
