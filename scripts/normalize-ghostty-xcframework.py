#!/usr/bin/env python3
"""Normalize AgentStudio's copied archive names for SwiftPM; never edit vendors."""
import os
import pathlib
import plistlib
import subprocess

framework = pathlib.Path(__file__).resolve().parent.parent / "Frameworks/GhosttyKit.xcframework"
if framework.parent.is_symlink() or framework.is_symlink():
    raise SystemExit("Refusing to normalize a shared framework symlink")
framework_root = framework.resolve(strict=True)
plist_path = framework / "Info.plist"
if plist_path.is_symlink():
    raise SystemExit("Refusing a symlinked framework manifest")
with plist_path.open("rb") as stream:
    metadata = plistlib.load(stream)
for library in metadata["AvailableLibraries"]:
    identifier = library["LibraryIdentifier"]
    if identifier in (".", "..") or pathlib.Path(identifier).name != identifier:
        raise SystemExit(f"Unexpected library identifier: {identifier}")
    directory = framework / identifier
    if directory.is_symlink() or not directory.resolve(strict=True).is_relative_to(framework_root):
        raise SystemExit("Library directory escapes copied framework")
    original = library["LibraryPath"]
    if pathlib.Path(original).name != original or not original.endswith(".a"):
        raise SystemExit(f"Unexpected static archive name: {original}")
    normalized = original if original.startswith("lib") else f"lib{original}"
    archive = directory / original
    destination = directory / normalized
    if archive.is_symlink() or destination.is_symlink():
        raise SystemExit("Refusing a symlinked archive")
    if not archive.resolve(strict=True).is_relative_to(framework_root):
        raise SystemExit("Archive escapes copied framework")
    if normalized != original:
        if destination.exists():
            raise SystemExit("Normalized archive destination already exists")
        archive.rename(destination)
        library["LibraryPath"] = normalized
        if library.get("BinaryPath") == original:
            library["BinaryPath"] = normalized
    # SwiftPM's Swift Build engine copies every binary target's headers into one
    # shared Products/<config>/include/. GhosttyKit and agentstudio-git's
    # CLibGit2Local both ship Headers/module.modulemap at the root, so the two
    # module maps collide there. Nesting ours under Headers/GhosttyKit/ gives it a
    # unique path; Clang still finds it as <search dir>/GhosttyKit/module.modulemap.
    headers = directory / library.get("HeadersPath", "Headers")
    nested = headers / "GhosttyKit"
    if headers.is_symlink() or not headers.resolve(strict=True).is_relative_to(framework_root):
        raise SystemExit("Headers directory escapes copied framework")
    if not (nested / "module.modulemap").exists():
        nested.mkdir()
        for entry in sorted(headers.iterdir()):
            if entry != nested:
                entry.rename(nested / entry.name)
    # strip rewrites archive member dates; stable dates keep the copied
    # framework digest identical across fresh CI runners.
    subprocess.run(
        ["xcrun", "strip", "-S", str(directory / normalized)],
        check=True,
        env={**os.environ, "ZERO_AR_DATE": "1"},
    )
with plist_path.open("wb") as stream:
    plistlib.dump(metadata, stream, sort_keys=False)
