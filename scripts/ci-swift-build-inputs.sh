#!/usr/bin/env bash
set -euo pipefail

# The inventory and comparison need byte-level and nanosecond-level filesystem
# operations; keep their implementation together so every command uses one rule.
exec python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

SCHEME = 1
ROOT = Path(os.environ.get("CI_SWIFT_ROOT", ".")).resolve()
BUILD = Path(os.environ.get("CI_SWIFT_BUILD_PATH", ".build-ci"))
CACHE_NAMESPACE = os.environ.get("CI_SWIFT_CACHE_NAMESPACE", "swift-build-v1-")
TRUSTED_PRODUCER_REF = os.environ.get("CI_SWIFT_TRUSTED_PRODUCER_REF", "refs/heads/main")
RESOURCE_ROOTS = (
    "Sources/AgentStudio/Resources/Icons.xcassets",
    "Sources/AgentStudio/Resources/AppIcon.icns",
    "Sources/AgentStudio/Resources/AppLogoTransparent.svg",
    "Sources/AgentStudio/Resources/AppIcon.iconset",
    "Sources/AgentStudio/Resources/terminfo",
    "Sources/AgentStudio/Resources/ghostty",
    "Sources/AgentStudio/Resources/BridgeWeb",
    "Tests/AgentStudioIPCClientTests/Fixtures",
)
FRAMEWORK_ROOT = "Frameworks/GhosttyKit.xcframework"
STRICT_TREE_ROOTS = RESOURCE_ROOTS + (FRAMEWORK_ROOT,)


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def command_output(args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def file_digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def tree_digest(path):
    if not path.exists() and not path.is_symlink():
        return "absent"
    if path.is_symlink():
        return digest_bytes(os.readlink(path).encode())
    if path.is_file():
        return file_digest(path)
    children = []
    for child in sorted(path.iterdir(), key=lambda item: item.name):
        mode = stat.S_IMODE(child.lstat().st_mode)
        children.append([child.name, mode, tree_digest(child)])
    return digest_bytes(canonical(children))


def gitlink(path):
    override = os.environ.get("CI_SWIFT_" + path.upper() + "_GITLINK")
    return override or command_output(["git", "rev-parse", "HEAD:vendor/" + path])


def fingerprint_inputs():
    def configured(name, fallback):
        return os.environ.get(name) or fallback()

    compiler = configured("CI_SWIFT_COMPILER_VERSION", lambda: command_output(["swift", "--version"]))
    xcode = configured("CI_SWIFT_XCODE_BUILD", lambda: command_output(["xcodebuild", "-version"]))
    sdk = configured("CI_SWIFT_SDK_BUILD", lambda: command_output(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]))
    return {
        "scheme": SCHEME,
        "os": configured("CI_SWIFT_OS", lambda: command_output(["uname", "-s"])),
        "arch": configured("CI_SWIFT_ARCH", lambda: command_output(["uname", "-m"])),
        "compiler": compiler,
        "xcode": xcode,
        "sdk": sdk,
        "deployment": os.environ.get("MACOSX_DEPLOYMENT_TARGET", "26.0"),
        "configuration": os.environ.get("CI_SWIFT_CONFIGURATION", "debug"),
        "package": tree_digest(ROOT / "Package.swift"),
        "resolved": tree_digest(ROOT / "Package.resolved"),
        "ghostty_gitlink": gitlink("ghostty"),
        "zmx_gitlink": gitlink("zmx"),
        "framework": tree_digest(ROOT / "Frameworks/GhosttyKit.xcframework"),
        "build_path": str(BUILD),
        "stats_mode": bool(os.environ.get("SWIFT_BUILD_STATS_DIR")),
        "stats_path": os.environ.get("SWIFT_BUILD_STATS_DIR", ""),
        "extra_flags": os.environ.get("EXTRA_SWIFT_TEST_ARGS", ""),
        "prebuild_helper": file_digest(Path(os.environ.get(
            "CI_SWIFT_PREBUILD_HELPER_PATH", ROOT / "scripts/swift-test-helpers.sh"))),
        "verifier": file_digest(Path(os.environ.get(
            "CI_SWIFT_VERIFIER_PATH", ROOT / "scripts/ci-swift-build-inputs.sh"))),
    }


def fingerprint():
    values = fingerprint_inputs()
    if os.environ.get("CI_SWIFT_FINGERPRINT_EXPLAIN") == "1":
        for name, value in sorted(values.items()):
            print(name + " " + digest_bytes(canonical(value)), file=sys.stderr)
    return digest_bytes(canonical(values))


def is_strict_tree_input(path):
    return path == "Frameworks" or any(
        path == root or path.startswith(root + "/") for root in STRICT_TREE_ROOTS)


def admitted_paths():
    names = set()
    if os.environ.get("CI_SWIFT_ALL_FILES") == "1":
        for root_name in ("Sources", "Tests"):
            root_path = ROOT / root_name
            if root_path.exists():
                names.add(root_name)
                for current, directories, files in os.walk(root_path, followlinks=False):
                    relative = Path(current).relative_to(ROOT).as_posix()
                    names.add(relative)
                    names.update((Path(relative) / name).as_posix() for name in directories + files)
    else:
        raw = subprocess.check_output(["git", "ls-files", "-z", "--", "Sources", "Tests"], cwd=ROOT)
        names.update(name.decode() for name in raw.split(b"\0") if name)
    names.update(("Package.swift", "Package.resolved"))
    for root_name in STRICT_TREE_ROOTS:
        path = ROOT / root_name
        if path.exists() or path.is_symlink():
            names.add(root_name)
            if path.is_dir() and not path.is_symlink():
                for current, directories, files in os.walk(path, followlinks=False):
                    relative = Path(current).relative_to(ROOT).as_posix()
                    names.add(relative)
                    names.update((Path(relative) / name).as_posix() for name in directories + files)
    for name in list(names):
        parent = Path(name).parent
        while str(parent) != ".":
            names.add(parent.as_posix())
            parent = parent.parent
    return sorted(names)


def record(path_name):
    path = ROOT / path_name
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        target = os.readlink(path)
        resolved = path.resolve()
        if not resolved.is_relative_to(ROOT) or not resolved.exists() or not (
            resolved.relative_to(ROOT).parts[0] in ("Sources", "Tests")
            or resolved.relative_to(ROOT).as_posix() in ("Package.swift", "Package.resolved")
            or is_strict_tree_input(resolved.relative_to(ROOT).as_posix())
        ):
            raise ValueError("symlink leaves inventory: " + path_name)
        referent = tree_digest(resolved)
        kind = "symlink"
        digest = digest_bytes(canonical([target, referent]))
    elif stat.S_ISDIR(info.st_mode):
        kind = "directory"
        members = [[child.name, stat.S_IMODE(child.lstat().st_mode),
                    "directory" if child.is_dir() and not child.is_symlink() else
                    "symlink" if child.is_symlink() else "file"]
                   for child in sorted(path.iterdir(), key=lambda item: item.name)]
        digest = digest_bytes(canonical(members))
        target = None
        referent = None
    elif stat.S_ISREG(info.st_mode):
        kind = "file"
        digest = file_digest(path)
        target = None
        referent = None
    else:
        raise ValueError("unsupported input kind: " + path_name)
    return {"path": path_name, "kind": kind, "mode": mode, "digest": digest,
            "target": target, "referent": referent, "mtime_ns": info.st_mtime_ns}


def inventory():
    records = [record(name) for name in admitted_paths()]
    fp = fingerprint()
    prefix = CACHE_NAMESPACE + "{}-{}-{}-".format(
        os.environ.get("CI_SWIFT_OS", command_output(["uname", "-s"])),
        os.environ.get("CI_SWIFT_ARCH", command_output(["uname", "-m"])), fp)
    return {"scheme": SCHEME, "fingerprint": fp, "prefix": prefix,
            "producer_commit": os.environ.get("CI_SWIFT_PRODUCER_COMMIT", ""),
            "producer_run": os.environ.get("CI_SWIFT_PRODUCER_RUN", ""),
            "producer_ref": os.environ.get("CI_SWIFT_PRODUCER_REF", ""),
            "manifest_digest": digest_bytes(canonical(records)), "records": records}


def validated_manifest(path):
    value = json.loads(Path(path).read_text())
    if value.get("scheme") != SCHEME or not isinstance(value.get("records"), list):
        raise ValueError("scheme or records invalid")
    records = value["records"]
    names = []
    for item in records:
        name = item.get("path")
        if not isinstance(name, str) or not name or Path(name).is_absolute() or \
                ".." in Path(name).parts or name != Path(name).as_posix() or not (
                    name in ("Package.swift", "Package.resolved", "Sources", "Tests", "Frameworks")
                    or name.startswith("Sources/") or name.startswith("Tests/")
                    or name == FRAMEWORK_ROOT or name.startswith(FRAMEWORK_ROOT + "/")
                ):
            raise ValueError("path escapes inventory")
        if item.get("kind") not in ("file", "directory", "symlink") or \
                not isinstance(item.get("mode"), int) or \
                not 0 <= item["mode"] <= 0o7777 or \
                not isinstance(item.get("mtime_ns"), int) or \
                not isinstance(item.get("digest"), str) or \
                re.fullmatch(r"[a-f0-9]{64}", item["digest"]) is None:
            raise ValueError("malformed record")
        if item["kind"] == "symlink":
            if not isinstance(item.get("target"), str) or not isinstance(item.get("referent"), str) or \
                    re.fullmatch(r"[a-f0-9]{64}", item["referent"]) is None:
                raise ValueError("malformed symlink record")
        names.append(name)
    if names != sorted(set(names)) or value.get("manifest_digest") != digest_bytes(canonical(records)):
        raise ValueError("duplicate, unsorted, or invalid manifest")
    return value


def compare(seed, current):
    prefix_pattern = re.compile(r"^" + re.escape(CACHE_NAMESPACE) + r"[^-]+-[^-]+-[a-f0-9]{64}-$")
    if not seed.get("producer_commit") or not str(seed.get("producer_run", "")).isdigit() or \
            seed.get("producer_ref") != TRUSTED_PRODUCER_REF or \
            not isinstance(seed.get("prefix"), str) or \
            prefix_pattern.fullmatch(seed["prefix"]) is None or \
            seed.get("prefix") != current.get("prefix") or \
            seed.get("fingerprint") != current.get("fingerprint"):
        raise ValueError("seed provenance or prefix mismatch")
    previous = {item["path"]: item for item in seed["records"]}
    fresh = {item["path"]: item for item in current["records"]}
    stamps = []
    for name in sorted(previous.keys() | fresh.keys()):
        old = previous.get(name)
        new = fresh.get(name)
        if old is None:
            if is_strict_tree_input(name) or new["kind"] != "file" or not name.endswith(".swift"):
                raise ValueError("unsafe added input: " + name)
            continue
        if new is None:
            raise ValueError("deleted input: " + name)
        if old["kind"] != new["kind"] or old["mode"] != new["mode"]:
            raise ValueError("kind or mode transition: " + name)
        if old["kind"] == "symlink" and (old.get("target") != new.get("target") or
                                           old.get("referent") != new.get("referent")):
            raise ValueError("symlink transition: " + name)
        if is_strict_tree_input(name) and old["kind"] == "directory" and old["digest"] != new["digest"]:
            raise ValueError("resource membership transition: " + name)
        if old["kind"] == "directory":
            if old["digest"] == new["digest"]:
                stamps.append((name, old["mtime_ns"]))
            continue
        if old["digest"] == new["digest"] and old.get("target") == new.get("target") and \
                old.get("referent") == new.get("referent"):
            stamps.append((name, old["mtime_ns"]))
        elif new["mtime_ns"] == old["mtime_ns"]:
            raise ValueError("changed input has seed time: " + name)
    return stamps


def cold(reason):
    if BUILD.exists():
        shutil.rmtree(BUILD)
    print("cold " + reason)


def report_swift_input_changes(seed, current):
    previous = {item["path"]: item for item in seed["records"]}
    changed_count = sum(
        item["kind"] == "file" and item["path"].endswith(".swift") and (
            item["path"] not in previous or
            item["digest"] != previous[item["path"]]["digest"])
        for item in current["records"]
    )
    print("lane-report swift_cache_seed_commit=" + seed["producer_commit"], file=sys.stderr)
    print("lane-report swift_cache_tested_tree=" + current["producer_commit"], file=sys.stderr)
    print("lane-report swift_cache_changed_swift_inputs=" + str(changed_count), file=sys.stderr)


def main():
    if len(sys.argv) < 2:
        raise ValueError("expected fingerprint, inventory, verify, or restamp")
    action = sys.argv[1]
    if action == "fingerprint" and len(sys.argv) == 2:
        print(CACHE_NAMESPACE + "{}-{}-{}-".format(
            os.environ.get("CI_SWIFT_OS", command_output(["uname", "-s"])),
            os.environ.get("CI_SWIFT_ARCH", command_output(["uname", "-m"])), fingerprint()))
    elif action == "inventory" and len(sys.argv) == 3:
        output = Path(sys.argv[2])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(inventory(), sort_keys=True, indent=2) + "\n")
    elif action in ("verify", "restamp") and len(sys.argv) == 4:
        try:
            seed = validated_manifest(sys.argv[2])
            current = validated_manifest(sys.argv[3])
            stamps = compare(seed, current)
            if action == "restamp":
                for name, stamp in sorted(stamps, key=lambda item: item[0].count("/"), reverse=True):
                    input_path = ROOT / name
                    os.utime(input_path, ns=(input_path.lstat().st_atime_ns, stamp), follow_symlinks=False)
                    if input_path.lstat().st_mtime_ns != stamp:
                        raise ValueError("stamp read-back mismatch: " + name)
                report_swift_input_changes(seed, current)
            print("warm " + seed["producer_commit"] + " r" + str(seed["producer_run"]) +
                  " " + seed["manifest_digest"])
        except (OSError, ValueError, OverflowError, KeyError, TypeError, json.JSONDecodeError) as error:
            cold(str(error))
    else:
        raise ValueError("invalid arguments")


try:
    main()
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print("ci-swift-build-inputs: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
