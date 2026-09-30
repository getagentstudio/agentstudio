#!/usr/bin/env bash
# Fails when a debt ledger raises a count or adds a row compared with the same
# ledger at the merge base of HEAD and the given base ref (default origin/main).
# The lint runs cannot see history, so this check owns the only-decrease rule
# for every Swift architecture and BridgeWeb debt ledger. They share one
# format, so the architecture lint tool compares each ledger.
#
# A merge base that has no copy of a ledger passes for that ledger: the change
# that introduces it records its initial baseline. A merge base that cannot be computed
# fails; the fix is enough fetched history, never skipping the check.
#
# Usage: Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh [base-ref]
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"

base_ref="${1:-origin/main}"
ledger_paths=(
  "Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv"
  "Tools/AgentStudioArchitectureLint/forbidden-test-wait-ledger.tsv"
  "Tools/AgentStudioArchitectureLint/adhoc-continuation-wait-ledger.tsv"
  "BridgeWeb/architecture-debt-ledger.tsv"
)

if ! merge_base="$(git merge-base HEAD "$base_ref")"; then
  echo "check-ledger-ratchet: cannot compute the merge base of HEAD and ${base_ref}; fetch full history" >&2
  exit 1
fi
echo "check-ledger-ratchet: comparing ${ledger_paths[*]} with merge base ${merge_base} (${base_ref})"

source "${repository_root}/scripts/swift-build-slot.sh"
swift_build_slot_acquire build "debt ledger ratchet"
trap swift_build_slot_release EXIT
build_path="${repository_root}/${SWIFT_BUILD_DIR}/architecture-lint"
swift build -c release --package-path Tools/AgentStudioArchitectureLint \
  --build-path "$build_path" \
  --product agentstudio-architecture-lint

# Each merge-base copy lives in this checkout's build slot, beside the tool.
# A copy is absent when the merge base has no such ledger.
ratchet_status=0
for ledger_path in "${ledger_paths[@]}"; do
  base_ledger_copy="${build_path}/merge-base-${ledger_path//\//-}"
  rm -f "$base_ledger_copy"
  if git cat-file -e "${merge_base}:${ledger_path}" 2>/dev/null; then
    git show "${merge_base}:${ledger_path}" > "$base_ledger_copy"
  fi
  echo "check-ledger-ratchet: ${ledger_path}"
  "${build_path}/release/agentstudio-architecture-lint" \
    --ledger "$ledger_path" \
    --check-ledger-ratchet "$base_ledger_copy" || ratchet_status=1
done
exit "$ratchet_status"
