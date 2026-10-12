#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
source "$PROJECT_ROOT/scripts/swift-build-slot.sh"
swift_build_slot_acquire test "terminal DI compile constraints"
trap swift_build_slot_release EXIT
products_path="$PROJECT_ROOT/$SWIFT_BUILD_DIR/out/Products/Debug"
fixtures_path="$PROJECT_ROOT/Tests/AgentStudioTests/Fixtures/TerminalDICompileFailures"
package_name="$(basename "$PROJECT_ROOT" | tr '.-' '__')"
if [ ! -d "$products_path/AgentStudioTerminal.swiftmodule" ]; then
  echo '[terminal-di-compile-negative] ERROR run mise run test:swift:prebuild first' >&2
  exit 1
fi
compiler_arguments=(-typecheck -swift-version 6 -strict-concurrency=complete -warnings-as-errors
  -module-cache-path "$PROJECT_ROOT/$SWIFT_BUILD_DIR/terminal-di-module-cache"
  -package-name "$package_name" -target "$(uname -m)-apple-macos26.0" -I "$products_path"
  -F "$PROJECT_ROOT/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64")
while IFS= read -r module_map; do
  compiler_arguments+=(-Xcc "-fmodule-map-file=$module_map")
done < <(rg --files "$PROJECT_ROOT/$SWIFT_BUILD_DIR/out/Intermediates.noindex/GeneratedModuleMaps" -g '*.modulemap')
# These custom C module maps are the same transitive imports used by the native Swift build.
for relative_module_map in \
  GRDB.swift/Sources/GRDBSQLite/module.modulemap \
  swift-atomics/Sources/_AtomicsShims/include/module.modulemap \
  swift-numerics/Sources/_NumericsShims/include/module.modulemap \
  swift-system/Sources/CSystem/include/module.modulemap \
  swift-nio-ssl/Sources/CNIOBoringSSL/include/module.modulemap \
  swift-crypto/Sources/CCryptoBoringSSLShims/include/module.modulemap \
  swift-crypto/Sources/CCryptoBoringSSL/include/module.modulemap \
  swift-nio/Sources/CNIOWindows/include/module.modulemap; do
  compiler_arguments+=(-Xcc "-fmodule-map-file=$PROJECT_ROOT/$SWIFT_BUILD_DIR/checkouts/$relative_module_map")
done
compiler_arguments+=(-Xcc "-I$products_path/include")
fixture_base="$(mktemp -t agentstudio-terminal-di-fixture)"
fixture_swift="$fixture_base.swift"
diagnostic_path="$(mktemp -t agentstudio-terminal-di-diagnostics)"
mv "$fixture_base" "$fixture_swift"
finish_compile_constraints() {
  rm -f "$fixture_swift" "$diagnostic_path"
  swift_build_slot_release
}
trap finish_compile_constraints EXIT
compile_fixture() {
  cp "$fixtures_path/$1.swift.fixture" "$fixture_swift"
  swiftc "${compiler_arguments[@]}" "$fixture_swift" > "$diagnostic_path" 2>&1
}
if ! compile_fixture OwnedIngressAndActorApply; then
  echo '[terminal-di-compile-negative] ERROR positive fixture failed' >&2
  cat "$diagnostic_path" >&2
  exit 1
fi
verify_negative() {
  local fixture_name="$1" expected_first="$2" expected_second="$3"
  if compile_fixture "$fixture_name"; then
    echo "[terminal-di-compile-negative] ERROR $fixture_name compiled" >&2
    exit 1
  fi
  if ! rg -Fq "$expected_first" "$diagnostic_path" || ! rg -Fq "$expected_second" "$diagnostic_path"; then
    echo "[terminal-di-compile-negative] ERROR $fixture_name failed unexpectedly" >&2
    cat "$diagnostic_path" >&2
    exit 1
  fi
  echo "[terminal-di-compile-negative] PASS $fixture_name"
}
verify_negative BorrowedPointerCannotEnterOwnedIngress "UnsafeMutableRawPointer" "expected argument type 'GhosttyOwnedCallbackWork'"
verify_negative NativeApplyRequiresMainActor "main actor-isolated instance method 'isCurrentSurfaceLifetime" "synchronous nonisolated context"
echo '[terminal-di-compile-negative] PASS owned ingress and MainActor apply boundaries'
