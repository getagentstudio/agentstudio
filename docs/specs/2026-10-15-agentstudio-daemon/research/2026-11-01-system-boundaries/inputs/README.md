# Retained native experiment inputs

These files preserve the inputs and filtered observations from the local 2026-11-01 qualification work. The [results](../native-continuity-results.md) define the supported claim and its limits; [input hashes](../native-continuity-result.json) bind the three driver snapshots and schema excerpt.

The scripts were executed from the repository root while located in `tmp/practices-research/2026-11-01-system-boundaries/`. Their relative Zod import and fixture/configuration paths refer to that original context. These retained copies are evidence, not relocatable commands. Do not execute them from this folder or reuse the recorded conversation IDs as a fresh fixture.

| Retained file | Meaning |
| --- | --- |
| `run-native-control-client-probe.mts` | Initial manual attempt; inconclusive for requester SIGKILL |
| `run-armed-native-continuity-probe.mts` | Corrected, event-driven driver used for the successful case |
| `read-native-fixture-diagnostic.mts` | Read-only metadata/command diagnostic for the owned fixture |
| `continuity-probe-events.jsonl` | Filtered initial-attempt events |
| `continuity-probe-armed-events.jsonl` | Two armed attempts, each beginning with `registered-probe`; the final run passed |
| `continuity-probe-native-diagnostic.json` | Earlier attempts' command metadata and fixture output |
| `continuity-probe-preflight.json` | Exact fixture/caller/configuration identities; no credentials |
| `continuity-probe-gate-prompt.txt` | Initial manual-attempt prompt |
| `gate-prompt-successful.txt` | Exact generated prompt for the successful armed run |
| `post-run-sdk-observation.json` | Filtered later SDK identity/generation/status; fixture was not loaded |
| `tsconfig.probe.json` | Compiler inputs used in the original scratch location |

The event records contain selected identities, status, command metadata and the experiment's own gate value. They are not a complete provider transcript. The native diagnostic response was filtered before saving; reasoning text was not printed or retained.
