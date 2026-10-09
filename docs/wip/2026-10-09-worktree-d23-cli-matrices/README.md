# D23 debug-CLI matrices (worktree `new` / `new -c`)

Behavior matrices for `agentstudio worktree new` after owner decisions D13–D23, run against a built CLI binary. Each script prints `ok` / `FAIL` per row, then `pass=N fail=M`, and exits non-zero on any failure. They need `/bin/bash` 3.2 or later, git, and network access for the HTTPS origins.

| Script | What it covers |
|---|---|
| `dbg-branch-matrix.sh <cli> <work-dir>` | Synthetic repositories with a local bare origin. That origin uses file transport, which the production client won't ask, so creating rows pass `--no-fetch` and the matrix checks `-c`'s fail-closed `originCheckFailed`. |
| `dbg-remote-matrix.sh <cli> <work-dir>` | A real HTTPS origin, read-only (no pushes): opening and creating, `branchAlreadyExists` for an origin-only name, `--no-fetch`, an unreachable origin, and no origin remote. |
| `dbg-real-checkout.sh <cli> <work-dir>` | One real agentstudio clone: `new -c <b> --from-branch origin/main`, a clean status at `origin/main` apart from listed submodules, the one created line, then `remove` with the CLI. |
| `run-matrix-receipt.sh <matrix> <cli> <work-dir> <receipt> <app-head>` | Wraps one run as a raw receipt with the script's and binary's hashes. |

`<work-dir>` must not exist yet. Run them against the 0.0.110 release helper as its smoke, using the full Helpers path and never bare `agentstudio`:

```bash
CLI="/Applications/AgentStudio.app/Contents/Helpers/agentstudio"
bash run-matrix-receipt.sh dbg-branch-matrix.sh "$CLI" /tmp/d23-branch d23-branch.log <app-head>
```

Expected values were derived from the source and test goldens at `891ef01a5` (#489). Each row's expected value and its source anchor are in [ANCHORS.md](ANCHORS.md).
