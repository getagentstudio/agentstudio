#!/bin/bash
# Read-only identity inspection shared by the debug launcher and its verifier.

process_start_identity() {
  local pid="${1:?missing pid}"
  if [ "${AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES:-0}" = "1" ]; then
    printf '%s\n' "${AGENTSTUDIO_OBSERVABILITY_TEST_PROCESS_START_IDENTITY:-test-process-start-$pid}"
    return 0
  fi
  /usr/bin/python3 - "$pid" <<'PY'
import ctypes
import sys

MAXCOMLEN = 16
PROC_PIDTBSDINFO = 3

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
libproc.proc_pidinfo.restype = ctypes.c_int
info = ProcBSDInfo()
size = ctypes.sizeof(info)
result = libproc.proc_pidinfo(int(sys.argv[1]), PROC_PIDTBSDINFO, 0, ctypes.byref(info), size)
if result != size or info.pbi_pid != int(sys.argv[1]):
    sys.exit(1)
print(f"{info.pbi_start_tvsec}:{info.pbi_start_tvusec}")
PY
}

bundle_path_for_executable() {
  local executable_path="${1:?missing executable path}"
  case "$executable_path" in
    *.app/Contents/MacOS/AgentStudio)
      printf '%s\n' "${executable_path%/Contents/MacOS/AgentStudio}"
      ;;
  esac
}

bundle_identifier_for_executable() {
  local executable_path="${1:?missing executable path}"
  local bundle_path
  bundle_path="$(bundle_path_for_executable "$executable_path")"
  [ -n "$bundle_path" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle_path/Contents/Info.plist" 2>/dev/null || true
}

debug_code_for_executable() {
  local executable_path="${1:?missing executable path}"
  local bundle_path
  bundle_path="$(bundle_path_for_executable "$executable_path")"
  [ -n "$bundle_path" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :AgentStudioDebugCode' "$bundle_path/Contents/Info.plist" 2>/dev/null || true
}

# Print-identity can describe a not-yet-built bundle. If it already exists,
# its signed metadata must agree before a workload may reset its data root.
debug_bundle_path_matches_code() {
  local code="${1:?missing debug code}"
  local app_path="${2:?missing app path}"
  local executable_path="${3:?missing executable path}"
  case "$app_path" in
    *"/AgentStudio Debug $code.app") ;;
    *) return 1 ;;
  esac
  [ "$executable_path" = "$app_path/Contents/MacOS/AgentStudio" ] || return 1
  if [ -e "$app_path" ]; then
    [ "$(bundle_identifier_for_executable "$executable_path")" = com.agentstudio.app.debug ] &&
      [ "$(debug_code_for_executable "$executable_path")" = "$code" ] || return 1
  fi
}
