#!/usr/bin/env bash
# Shared compilation arguments for the CI seed producer and its consumers.
# The sandbox helper retains its source-time module-cache initialization.
if ! source "${CI_SWIFT_SANDBOX_POLICY_PATH:-$(dirname "${BASH_SOURCE[0]}")/swift-package-sandbox.sh}"; then
  echo "swift-compilation-policy: sandbox policy could not be loaded" >&2
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 2; else return 2; fi
fi

swift_compilation_policy_resolve() {
  SWIFT_COMPILATION_BUILD_PATH="$1"
  SWIFT_COMPILATION_SANDBOX_ARGUMENTS=()
  SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS=()
  SWIFT_COMPILATION_EXTRA_ARGUMENTS=()
  SWIFT_COMPILATION_STATISTICS_ARGUMENTS=()
  SWIFT_COMPILATION_STATISTICS_PATH=""
  SWIFT_COMPILATION_CONFIGURATION="${CI_SWIFT_CONFIGURATION:-debug}"

  local sandbox_argument sandbox_arguments
  sandbox_arguments="$(swift_package_sandbox_arguments)" || return $?
  while IFS= read -r sandbox_argument; do
    [ -z "$sandbox_argument" ] || SWIFT_COMPILATION_SANDBOX_ARGUMENTS+=("$sandbox_argument")
  done <<<"$sandbox_arguments"

  if [ -n "${CI_SWIFT_CONFIGURATION:-}" ]; then
    SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS=(-c "$CI_SWIFT_CONFIGURATION")
  fi
  # Preserve the existing callers' shell-word expansion without eval.
  # shellcheck disable=SC2206
  SWIFT_COMPILATION_EXTRA_ARGUMENTS=(${EXTRA_SWIFT_TEST_ARGS:-})

  if [ -n "${SWIFT_BUILD_STATS_DIR:-}" ]; then
    if [[ "$SWIFT_BUILD_STATS_DIR" = /* ]] && mkdir -p "$SWIFT_BUILD_STATS_DIR" 2>/dev/null; then
      SWIFT_COMPILATION_STATISTICS_PATH="$SWIFT_BUILD_STATS_DIR"
      SWIFT_COMPILATION_STATISTICS_ARGUMENTS=(-Xswiftc -stats-output-dir -Xswiftc "$SWIFT_BUILD_STATS_DIR")
    else
      echo "[swift-compilation-policy] warning: compiler statistics disabled (directory must be writable and absolute)" >&2
    fi
  fi

  SWIFT_COMPILATION_COMMON_ARGUMENTS=(
    ${SWIFT_COMPILATION_SANDBOX_ARGUMENTS[@]+"${SWIFT_COMPILATION_SANDBOX_ARGUMENTS[@]}"}
    ${SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS[@]+"${SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS[@]}"}
    ${SWIFT_COMPILATION_EXTRA_ARGUMENTS[@]+"${SWIFT_COMPILATION_EXTRA_ARGUMENTS[@]}"}
    --build-path "$SWIFT_COMPILATION_BUILD_PATH"
    ${SWIFT_COMPILATION_STATISTICS_ARGUMENTS[@]+"${SWIFT_COMPILATION_STATISTICS_ARGUMENTS[@]}"}
  )
}

swift_compilation_policy_build_arguments() {
  local build_intent="$1"
  swift_compilation_policy_resolve "$2" || return $?
  case "$build_intent" in
    test-bundles)
      SWIFT_COMPILATION_COMMAND=(
        swift build ${SWIFT_COMPILATION_SANDBOX_ARGUMENTS[@]+"${SWIFT_COMPILATION_SANDBOX_ARGUMENTS[@]}"}
        ${SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS[@]+"${SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS[@]}"} --build-tests
        ${SWIFT_COMPILATION_EXTRA_ARGUMENTS[@]+"${SWIFT_COMPILATION_EXTRA_ARGUMENTS[@]}"} --build-path "$SWIFT_COMPILATION_BUILD_PATH"
        ${SWIFT_COMPILATION_STATISTICS_ARGUMENTS[@]+"${SWIFT_COMPILATION_STATISTICS_ARGUMENTS[@]}"}
      )
      ;;
    bridge-development-server)
      SWIFT_COMPILATION_COMMAND=(
        swift build ${SWIFT_COMPILATION_SANDBOX_ARGUMENTS[@]+"${SWIFT_COMPILATION_SANDBOX_ARGUMENTS[@]}"}
        ${SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS[@]+"${SWIFT_COMPILATION_CONFIGURATION_ARGUMENTS[@]}"} ${SWIFT_COMPILATION_EXTRA_ARGUMENTS[@]+"${SWIFT_COMPILATION_EXTRA_ARGUMENTS[@]}"}
        --build-path "$SWIFT_COMPILATION_BUILD_PATH" --product agentstudio-bridge-dev-server
        ${SWIFT_COMPILATION_STATISTICS_ARGUMENTS[@]+"${SWIFT_COMPILATION_STATISTICS_ARGUMENTS[@]}"}
      )
      ;;
    bin-path)
      SWIFT_COMPILATION_COMMAND=(
        swift build "${SWIFT_COMPILATION_COMMON_ARGUMENTS[@]}" --show-bin-path
      )
      ;;
    *)
      echo "swift-compilation-policy: unknown build intent '$build_intent'" >&2
      return 2
      ;;
  esac
}

swift_compilation_policy_describe() {
  swift_compilation_policy_resolve "$1" || return $?
  python3 - "$SWIFT_COMPILATION_BUILD_PATH" "$SWIFT_COMPILATION_CONFIGURATION" \
    "$SWIFT_COMPILATION_STATISTICS_PATH" "${CLANG_MODULE_CACHE_PATH:-}" \
    "${SWIFT_COMPILATION_COMMON_ARGUMENTS[@]}" <<'PY'
import json
import sys

print(json.dumps({
    "build_path": sys.argv[1],
    "configuration": sys.argv[2],
    "statistics_path": sys.argv[3],
    "module_cache_path": sys.argv[4],
    "common_arguments": sys.argv[5:],
}, sort_keys=True, separators=(",", ":")))
PY
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  if [ "${1:-}" != describe ] || [ "$#" -ne 2 ]; then
    echo "usage: swift-compilation-policy.sh describe <build-path>" >&2
    exit 2
  fi
  swift_compilation_policy_describe "$2"
fi
