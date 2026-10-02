#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

bash "$PROJECT_ROOT/scripts/vendor-worktree.sh" verify
source "$PROJECT_ROOT/scripts/swift-build-slot.sh"
source "$PROJECT_ROOT/scripts/swift-package-sandbox.sh"
swift_build_slot_acquire build "mise run build-bridge-development-server"
trap swift_build_slot_release EXIT

echo "[build-bridge-development-server] BUILD_PATH=$SWIFT_BUILD_DIR"
source "${CI_SWIFT_COMPILATION_POLICY_PATH:-$PROJECT_ROOT/scripts/swift-compilation-policy.sh}"
swift_compilation_policy_build_arguments bridge-development-server "$SWIFT_BUILD_DIR"
"${SWIFT_COMPILATION_COMMAND[@]}"

swift_compilation_policy_build_arguments bin-path "$SWIFT_BUILD_DIR"
swift_bin_path="$("${SWIFT_COMPILATION_COMMAND[@]}")"
source_executable="$swift_bin_path/agentstudio-bridge-dev-server"
artifact_directory="$PROJECT_ROOT/.build-bridge-development-server"
artifact_executable="$artifact_directory/agentstudio-bridge-dev-server"

mkdir -p "$artifact_directory"
temporary_executable="$(mktemp "$artifact_directory/.agentstudio-bridge-dev-server.XXXXXX")"
if ! install -m 755 "$source_executable" "$temporary_executable"; then
  rm -f "$temporary_executable"
  exit 1
fi
mv -f "$temporary_executable" "$artifact_executable"

echo "[build-bridge-development-server] executable=$artifact_executable"
