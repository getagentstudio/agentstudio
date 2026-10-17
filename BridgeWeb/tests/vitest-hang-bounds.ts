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

// A 50 s poll names its failure only when it starts within the first 10 s of
// the 60 s browser test. Later polls can end at the generic test hang bound.
// No current hooks poll; hook polls are out of contract (30 s hook bound).
// TQ78 owns remaining-test-time capping and pending-wait diagnostics.
export const browserExpectPollHangBoundMilliseconds = 50_000;

export const browserBenchmarkTestTimeoutMilliseconds = 15_000;

export const scriptBenchmarkTestTimeoutMilliseconds = 5_000;

// A real-backend journey on a 3-vCPU runner may legitimately be slow, so the
// E2E bound is wide; it still only stops a wedged run from hanging forever.
export const endToEndTestTimeoutMilliseconds = 600_000;

// A configured 500 s poll can name its failure first only when at least 500 s
// remain in the test (within the first 100 s of the default 600 s journey).
// Later polls and shorter per-test bounds can end in an unnamed runner failure.
// TQ78 owns remaining-test-time capping and pending-wait diagnostics.
export const endToEndExpectPollHangBoundMilliseconds = 500_000;

export const endToEndHookTimeoutMilliseconds = 60_000;
