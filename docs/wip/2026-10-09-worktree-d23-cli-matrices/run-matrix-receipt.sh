#!/bin/bash
# Wrap a matrix run as a raw receipt. Usage: run-matrix-receipt.sh <matrix-script> <cli> <workdir> <receipt-file> <app-head>
set -u
M="$1"; CLI="$2"; WORK="$3"; OUT="$4"; HEAD="$5"
{
  echo "# cwd: $(pwd)"
  echo "# matrix: $M (sha256 $(shasum -a 256 "$M" | cut -c1-16))"
  echo "# cli: $CLI (sha256 $(shasum -a 256 "$CLI" | cut -c1-16)), built from app head $HEAD"
  echo "# command: bash $M $CLI $WORK"
  echo "# started: $(date -u +%FT%TZ)"
  bash "$M" "$CLI" "$WORK"; rc=$?
  echo "# finished: $(date -u +%FT%TZ)"
  echo "# exit code: $rc"
} > "$OUT" 2>&1
grep -E "^pass=|exit code" "$OUT"
