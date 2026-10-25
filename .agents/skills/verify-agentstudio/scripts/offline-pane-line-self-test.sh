#!/bin/bash
# Real SQLite copy/parameterization checks, temporary OWNED fixture only.
offline_line_self_test() (
  set -euo pipefail
  umask 077
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/offline-pane-line.XXXXXX")"
  fixture_dir="$(cd "$fixture_dir" && pwd -P)"
  trap 'rm -rf -- "$fixture_dir"' EXIT
  pane_uuid=018f0000-0000-7000-8000-000000000001
  sqlite3 "$fixture_dir/source.sqlite" "CREATE TABLE pane_state(id TEXT,kind TEXT,pane_id TEXT,summary TEXT,updated_at INTEGER,writer_kind TEXT); INSERT INTO pane_state VALUES('line','agentLine','$pane_uuid','Running tests (3/7)',1800000000000000,'pane'); INSERT INTO pane_state VALUES('other','agentLine','018f0000-0000-7000-8000-000000000002','Other pane',1800000000000000,'pane');"
  offline_line_copy "$fixture_dir/source.sqlite" "$fixture_dir/aged.sqlite" "$pane_uuid" 1799308800000000 > "$fixture_dir/receipt.json"
  jq -e '.kind=="syntheticOfflineLineCopy" and .before.updatedAt==1800000000000000 and .after.updatedAt==1799308800000000 and .after.summary=="Running tests (3/7)"' "$fixture_dir/receipt.json" >/dev/null
  [ "$(sqlite3 -readonly "$fixture_dir/source.sqlite" "SELECT updated_at FROM pane_state WHERE id='line';")" = 1800000000000000 ]
  [ "$(sqlite3 -readonly "$fixture_dir/aged.sqlite" "SELECT updated_at FROM pane_state WHERE id='other';")" = 1800000000000000 ]
  if offline_line_copy "$fixture_dir/source.sqlite" "$fixture_dir/aged.sqlite" "$pane_uuid" 1 >/dev/null 2>&1; then exit 1; fi
  if offline_line_copy "$fixture_dir/source.sqlite" "$fixture_dir/missing.sqlite" 018f0000-0000-7000-8000-000000000009 1 >/dev/null 2>&1; then exit 1; fi
  [ ! -e "$fixture_dir/missing.sqlite" ]
  if offline_line_copy "$fixture_dir/source.sqlite" "$fixture_dir/injected.sqlite" "$pane_uuid" '1;DELETE FROM pane_state' >/dev/null 2>&1; then exit 1; fi
  [ ! -e "$fixture_dir/injected.sqlite" ]
  : > "$fixture_dir/source.sqlite-wal"
  if offline_line_copy "$fixture_dir/source.sqlite" "$fixture_dir/wal.sqlite" "$pane_uuid" 1 >/dev/null 2>&1; then exit 1; fi
  ln -s "$fixture_dir/source.sqlite" "$fixture_dir/source-link.sqlite"
  if offline_line_copy "$fixture_dir/source-link.sqlite" "$fixture_dir/linked.sqlite" "$pane_uuid" 1 >/dev/null 2>&1; then exit 1; fi
  printf '8 passed, 0 failed; real offline SQLite copy checks only, no app or live fixture\n'
)
