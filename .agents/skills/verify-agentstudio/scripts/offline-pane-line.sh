#!/bin/bash
# Copies an OWNED CLOSED fixture database, then changes one Agent Line timestamp
# in the NEW copy. Never edits the source, installs a fixture or starts an app.
set -euo pipefail
OFFLINE_LINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

offline_line_help() {
  cat <<'HELP'
offline-pane-line.sh --help | --self-test
offline-pane-line.sh copy CLOSED_SOURCE_DB NEW_COPY_DB PANE_UUID UPDATED_AT_MICROSECONDS

The later live commission must grant these exact offline fixture paths and own
the source app's confirmed retirement. Paths are absolute, non-symlinked, and
the destination must be new. Source WAL/journal sidecars must be absent. Source
must already contain exactly one nonempty agentLine for PANE_UUID. This helper
does not create topology, writer identity, a line body or a runtime fixture.
UPDATED_AT is the storage codec's integer Unix microseconds, not seconds.
Choose capture-time minus eight days for the no-expiry case; retain time bounds.
Output is the copy/timestamp receipt. The Lead separately loads this copy through
the declared debug datastore path BEFORE launch, then checks actual owner facts
and pixels. Copy/seed success is synthetic setup, never a journey PASS.
HELP
}

offline_line_copy() {
  local source_db="$1" destination_db="$2" pane_uuid="$3" updated_at="$4" before_line after_line
  [[ "$pane_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 2
  [[ "$updated_at" =~ ^(0|[1-9][0-9]{0,15})$ ]] || return 2
  for database_path in "$source_db" "$destination_db"; do
    case "$database_path" in /*) ;; *) echo 'Need absolute fixture paths' >&2; return 2 ;; esac
    case "$database_path" in *"'"*|*$'\n'*|*$'\r'*) echo 'Unsupported fixture path quoting' >&2; return 2 ;; esac
    [ ! -L "$database_path" ] && [ "$(realpath "$(dirname "$database_path")")/$(basename "$database_path")" = "$database_path" ] || return 2
  done
  [ -f "$source_db" ] && [ ! -e "$destination_db" ] && [ ! -e "$source_db-wal" ] && [ ! -e "$source_db-journal" ] || {
    echo 'Need a closed source and a new destination; HOLD' >&2; return 2;
  }
  before_line="$(sqlite3 -readonly "$source_db" "SELECT json_object('id',id,'summary',summary,'updatedAt',updated_at,'writerKind',writer_kind) FROM pane_state WHERE lower(pane_id)=lower('$pane_uuid') AND kind='agentLine' AND summary IS NOT NULL;")" || return
  jq -es 'length==1 and .[0].summary!=null' <<< "$before_line" >/dev/null || { echo 'Missing or ambiguous stored Agent Line' >&2; return 2; }
  # Claim only a new destination; a failed backup leaves that exact copy for inspection.
  ( set -o noclobber; : > "$destination_db" ) || return
  sqlite3 -readonly "$source_db" ".backup '$destination_db'" || return
  chmod 600 "$destination_db" || return
  sqlite3 "$destination_db" "BEGIN IMMEDIATE; UPDATE pane_state SET updated_at=$updated_at WHERE lower(pane_id)=lower('$pane_uuid') AND kind='agentLine' AND summary IS NOT NULL; COMMIT;" || return
  after_line="$(sqlite3 -readonly "$destination_db" "SELECT json_object('id',id,'summary',summary,'updatedAt',updated_at,'writerKind',writer_kind) FROM pane_state WHERE lower(pane_id)=lower('$pane_uuid') AND kind='agentLine' AND summary IS NOT NULL;")" || return
  jq -en --arg source "$source_db" --arg copy "$destination_db" --argjson before "$before_line" --argjson after "$after_line" --argjson timestamp "$updated_at" '
    if ($before|del(.updatedAt))==($after|del(.updatedAt)) and $after.updatedAt==$timestamp
    then {kind:"syntheticOfflineLineCopy",source:$source,copy:$copy,before:$before,after:$after}
    else error("Copied line identity/body changed or timestamp did not apply") end'
}

offline_line_main() {
  case "${1:---help}" in
    --help) offline_line_help ;;
    --self-test) source "$OFFLINE_LINE_DIR/offline-pane-line-self-test.sh"; offline_line_self_test ;;
    copy) [ "$#" -eq 5 ] || { offline_line_help >&2; return 2; }; shift; offline_line_copy "$@" ;;
    *) offline_line_help >&2; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then offline_line_main "$@"; fi
