# Annotation refresh and Copy/Export: Requirements

Date: 2026-10-15. Revision 4. The owner chose to fix the root of the Copy/Export race: the output request names the comments being output, instead of revisions 2–3's settlement holds.

Owner decisions, made in the CI Lead session that day:
- approve #560's sequencing (a source refresh waits for the committed demand acquisition);
- choose the proper product fix for the race it exposes;
- implement with clean scope.

## Who is affected and what goes wrong today

Anyone using the Bridge viewer's Annotations panel in Files or Review.

- **Refused refresh (TQ105, the most frequent hosted CI red).** After a file opens, the page sends `source.refresh` before native has committed the session's demand acquisition, and native refuses it with `conflict`. The Vite annotation journeys fail with "Expected committed source.refresh response, received … conflict". Observed in hosted runs 38317105183, 38577647543, 38674406756 and 38683665368. PR #560 makes the refresh wait for the commit.
- **Copy/Export conflicts that #560 exposes.** Once the refresh succeeds, it can advance native's annotation projection. While the page still shows the previous projection, Copy and Export are enabled. An output sent in that window binds the old projection, and native correctly answers `conflict` (PR1 rule). Reported evidence, from scratch instrumentation of the native WebKit Share journey on Sunclaw:
  - the File-half Export sent `displayedProjectionRevision: 5` 13 ms after the refresh reply and received `failed: conflict`;
  - main passed 6 of 6, main plus #560's client file failed 3 of 3.

  The exact native guard that rejected it was not captured. The first output guard compares the service projection revision, and is the leading candidate.
- **Demand that never recovers.** The original #560 client parks a session after three failed acquisitions. Only a worker convergence can recover it; a source change cannot. Reported as a deterministic held-transport unit red ("expected 4 acquisitions, received 3"); the saved receipts are in the Sunclaw tree's `tmp/tq105-fix-evidence/`.

## Requirements

| ID | Need | Priority |
|---|---|---|
| U1 | The page's source refresh after opening annotations is not refused because it was sent before the demand commit. | Must |
| U2 | Copy and Export fail with `conflict` only when a comment being copied actually changed or disappeared. They never fail because of a refresh, a re-anchor, or changes to other comments, sessions or worktrees. No new waiting or Updating state. | Must |
| U3 | Annotation demand recovers after repeated acquisition failures, without needing a worker replacement. | Must |
| U4 | When someone else (another pane, an agent over IPC) changed or removed a comment being copied, Copy/Export return an exact no-effect `conflict`, and Share stays open. | Must |

## Non-goals

- No change to Save, reply, edit or resolve fences. They use message, draft and thread revisions.
- No automatic retry of Copy or Export.
- No timers, polling, or new user-visible copy.
- Export content and order are unchanged: the stored original excerpt, the placement evaluated at export time, and native's canonical order. Owner decision 2026-10-15 (revision 5.1). The one exception: a Review export whose displayed publication was already replaced keeps today's rare `unavailable` result.
