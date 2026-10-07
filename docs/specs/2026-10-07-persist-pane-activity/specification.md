# Specification: pane activity survives an app restart

Requirements: `requirements.md` (U1–U4).

## Entities
- **E1 Pane activity record**: one per pane id, in the app-wide local database. It holds the pane's last PUBLISHED activity time (what the sidebar showed): wall time `at` (UTC) and `source` (`hook` | `terminal`). Identity is the pane id. It is retained while the pane exists in ANY persisted workspace or is a member of an available Undo record in any workspace. A prune in one workspace never deletes another workspace's activity.

## Obligations
| Id | Must | Traces |
|---|---|---|
| S1 | Each published activity batch is saved as one transaction, in publication order: the latest published wall time and source per pane. Publication keeps its existing per-pane coalescing (`AppPolicies.Panes.activityTimePublishInterval`, 10 s per pane). Save acknowledgement may lag publication. | U1, U2 |
| S2 | At launch, before the sidebar's first projection uses activity, every existing pane with a record shows an age equal to (now − record.at). It is clamped at 0 if the record's time is in the future. Its group, order and age chip match that age, and its source matches the record. | U1, U2 |
| S3 | A live activity time admitted at launch before restore finishes is never overwritten by an older restored record. | U1 |
| S4 | A record survives while its pane is live or is an available-Undo member, so close, restart, Undo restores the activity. Records for panes that are neither are deleted: at the live retirement (`.remove`) and at boot. A boot prune happens only when membership can be read; if the read fails, nothing is pruned. | U3 |
| S5 | Saving and restoring do no database I/O on the MainActor. Hook and terminal ingress never wait for a save. | U4 |
| S6 | A failed load starts with empty activity, as today. A failed save is logged, and publication continues. On quit, saving is best-effort within the existing termination drain bound: the latest unpublished activity may be lost. | U4 |

## Proof
- Unit/integration: save then restore round-trip; age derivation including a future time; live-wins-over-restore (S3); retire deletes; launch prunes missing panes; failure falls back.
- Integration: the real boot path against fresh and existing local databases; close, restart, Undo; a failed membership read skips the prune; a held commit still applies to the atom first, and later batches stay in order.
- Real app: a debug app with a real Claude turn in a pane, then an app restart. The pane keeps its group and age chip instead of "No activity". Captured by a PID-targeted screenshot plus `pane.snapshot` activity `{at, source}` (on main since #454).
