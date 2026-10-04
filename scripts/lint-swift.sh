#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
source "${repository_root}/scripts/swift-build-slot.sh"
source "${repository_root}/scripts/swift-package-sandbox.sh"
swift_build_slot_acquire build "mise run lint"
trap swift_build_slot_release EXIT

# Wall-clock milliseconds, for the per-stage timing lines. Timings are
# reported, never compared with a threshold: they cannot change the exit code.
now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

report_stage_time() {
  local stage="$1"
  local started_ms="$2"
  echo "lint-swift timing stage=${stage} ms=$(( $(now_ms) - started_ms ))"
}

# Builds the architecture lint tool in release (debug parsing is ~40x slower)
# inside this checkout's build slot, then lints. Arguments are passed to the
# tool: roots to parse, plus `--only <file>` for a scoped run.
run_architecture_lint() {
  echo "--- AgentStudio architecture lint ---"
  local build_path="${repository_root}/${SWIFT_BUILD_DIR}/architecture-lint"
  local stage_started_ms
  stage_started_ms="$(now_ms)"
  swift build $(swift_package_sandbox_arguments) -c release --package-path Tools/AgentStudioArchitectureLint \
    --build-path "$build_path" \
    --product agentstudio-architecture-lint 2>&1 \
    || { echo "agentstudio architecture lint: build FAIL"; exit 1; }
  report_stage_time "architecture-lint-build" "$stage_started_ms"

  stage_started_ms="$(now_ms)"
  local lint_status=0
  "${build_path}/release/agentstudio-architecture-lint" --timings \
    --ledger Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv \
    --ledger Tools/AgentStudioArchitectureLint/forbidden-test-wait-ledger.tsv \
    --ledger Tools/AgentStudioArchitectureLint/adhoc-continuation-wait-ledger.tsv \
    --ledger Tools/AgentStudioArchitectureLint/process-singleton-ledger.tsv \
    "$@" 2>&1 || lint_status=$?
  report_stage_time "architecture-lint" "$stage_started_ms"
  if [[ $lint_status -eq 0 ]]; then
    echo "agentstudio architecture lint: OK"
  else
    echo "agentstudio architecture lint: FAIL"
    exit 1
  fi
}

# Every tracked agent instruction document; the architecture lint checks that
# each path and anchor it references exists. The lint tool's own fixture
# documents are deliberately broken and are linted by its tests instead.
agent_documents() {
  local architecture_doc_fixture_root
  architecture_doc_fixture_root="$(cat "${repository_root}/scripts/architecture-doc-fixture-root.txt")"
  [[ -n "$architecture_doc_fixture_root" ]] || { echo "architecture doc fixture root is empty" >&2; return 1; }
  git ls-files -- 'AGENTS.md' '*/AGENTS.md' \
    ":(exclude)${architecture_doc_fixture_root}/**"
}

run_release_script_checks() {
  echo "--- release script checks ---"
  /bin/bash scripts/verify-release-scripts.sh
}

lint_started_ms="$(now_ms)"
run_portable_only=0
if [[ "${1:-}" == "--portable" ]]; then
  run_portable_only=1
  shift
fi

if [[ $# -eq 0 ]]; then
  echo "--- swift-format lint ---"
  stage_started_ms="$(now_ms)"
  swift-format lint --strict --parallel --recursive \
    Sources/ Tests/ \
    Tools/AgentStudioArchitectureLint/Sources \
    Tools/AgentStudioArchitectureLint/Tests 2>&1 \
    && echo "swift-format: OK" \
    || { echo "swift-format: FAIL"; exit 1; }
  report_stage_time "swift-format" "$stage_started_ms"

  echo "--- SwiftLint ---"
  stage_started_ms="$(now_ms)"
  # The cache lives in the held slot: agent sandboxes deny writes to ~/Library/Caches.
  swiftlint lint --strict --cache-path "${repository_root}/${SWIFT_BUILD_DIR}/swiftlint-cache" 2>&1 \
    && echo "swiftlint: OK" \
    || { echo "swiftlint: FAIL"; exit 1; }
  report_stage_time "swiftlint" "$stage_started_ms"

  agent_document_paths=()
  while IFS= read -r agent_document_path; do
    agent_document_paths+=("$agent_document_path")
  done < <(agent_documents)
  run_architecture_lint Sources Tests "${agent_document_paths[@]}"
  stage_started_ms="$(now_ms)"
  if [[ $run_portable_only -eq 0 ]]; then
    run_release_script_checks
    report_stage_time "release-script-checks" "$stage_started_ms"
  fi
  report_stage_time "total" "$lint_started_ms"
  exit 0
fi

scoped_paths=("$@")
for scoped_path in "${scoped_paths[@]}"; do
  if [[ "$scoped_path" = /* || "$scoped_path" == *".."* || ! -f "$scoped_path" ]]; then
    echo "lint-swift: scoped path must be an existing repository-relative file: $scoped_path" >&2
    exit 2
  fi
done

swift_scoped_paths=()
agent_document_scoped_paths=()
run_release_contract=0
for scoped_path in "${scoped_paths[@]}"; do
  case "$scoped_path" in
    *.swift)
      swift_scoped_paths+=("$scoped_path")
      ;;
    AGENTS.md|*/AGENTS.md)
      agent_document_scoped_paths+=("$scoped_path")
      ;;
    .github/workflows/release.yml|scripts/release-*|scripts/verify-release-scripts.sh)
      run_release_contract=1
      echo "lint-swift: routing release path to release checks: $scoped_path"
      ;;
    docs/*)
      echo "lint-swift: ignoring documentation path: $scoped_path"
      ;;
    *)
      echo "lint-swift: ignoring non-Swift path: $scoped_path"
      ;;
  esac
done

architecture_only_arguments=()
if [[ ${#swift_scoped_paths[@]} -gt 0 ]]; then
  echo "--- swift-format lint (scoped) ---"
  swift-format lint --strict --parallel "${swift_scoped_paths[@]}" 2>&1 \
    && echo "swift-format: OK" \
    || { echo "swift-format: FAIL"; exit 1; }

  echo "--- SwiftLint (scoped) ---"
  swiftlint lint --strict "${swift_scoped_paths[@]}" 2>&1 \
    && echo "swiftlint: OK" \
    || { echo "swiftlint: FAIL"; exit 1; }

  for swift_scoped_path in "${swift_scoped_paths[@]}"; do
    architecture_only_arguments+=(--only "$swift_scoped_path")
  done
fi
for agent_document_scoped_path in "${agent_document_scoped_paths[@]+"${agent_document_scoped_paths[@]}"}"; do
  architecture_only_arguments+=(--only "$agent_document_scoped_path")
done

if [[ ${#architecture_only_arguments[@]} -gt 0 ]]; then
  run_architecture_lint Sources Tests "${architecture_only_arguments[@]}"
else
  echo "lint-swift: no Swift-lintable paths remain"
fi

if [[ $run_release_contract -eq 1 ]]; then
  run_release_script_checks
else
  echo "--- release script checks: not affected by scoped paths ---"
fi
report_stage_time "total" "$lint_started_ms"
