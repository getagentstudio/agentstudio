#!/usr/bin/env python3
"""Classify changed files conservatively; a scanner failure keeps full CI."""

import argparse
import json
import os
import pathlib
import posixpath
import re
import subprocess
import sys
import typing as t
import urllib.parse

CODE_ROOTS = {"Tests", "Tools", "BridgeWeb", "web", "scripts"}
AGENT_DOC_NAMES = {"AGENTS.md", "CLAUDE.md"}
DOC_PATH = re.compile(r"\bdocs/[\w./+*?%-]+\.[\w]+\b")
QUOTED_PATH = re.compile(r"[\"'`]([^\"'`\n]+)[\"'`]")
REPOSITORY_PATH = re.compile(
    r"(?<![\w:/])(?:\.?/?[A-Za-z0-9_.+%-]+/)+[A-Za-z0-9_.+%*?=-]+(?:#[\w-]+)?"
)
BARE_REPOSITORY_FILE = re.compile(r"(?<![\w/])[A-Za-z0-9_.+-]+\.[A-Za-z0-9_-]+(?:#[\w-]+)?")
Scope = t.Literal["docs", "full"]


def git_output(root: pathlib.Path, *arguments: str) -> bytes:
    return subprocess.check_output(
        ["git", "-C", str(root), *arguments], stderr=subprocess.PIPE
    )


def tracked_files(root: pathlib.Path) -> t.List[str]:
    return [
        os.fsdecode(path)
        for path in git_output(root, "ls-files", "-z").split(b"\0")
        if path
    ]


def is_doc(path: str) -> bool:
    # Documentation scope is deliberately narrow: docs/** and top-level Markdown
    # only. Markdown inside any code/tooling folder remains code.
    path_value = pathlib.PurePosixPath(path)
    return path.startswith("docs/") or (
        len(path_value.parts) == 1
        and path.endswith(".md")
        and path_value.name not in AGENT_DOC_NAMES
    )


def repository_doc_paths(root: pathlib.Path, path: pathlib.Path) -> t.Set[str]:
    # Both are code inputs: changing a symlink alias can change what the
    # reader sees, and changing the target can change its contents.
    pins: t.Set[str] = set()
    for candidate in [pathlib.Path(os.path.abspath(path)), path.resolve()]:
        try:
            pins.add(candidate.relative_to(root).as_posix())
        except ValueError:
            continue
    return pins


def repository_path_candidates(reader: str, token: str) -> t.Set[str]:
    target = urllib.parse.unquote(token.split("#", 1)[0])
    if (
        not target
        or target.startswith(("http:", "https:", "//", "$"))
        or "\\" in target
    ):
        return set()
    candidates: t.Set[str] = set()
    reader_parent = pathlib.PurePosixPath(reader).parent
    for candidate in [pathlib.PurePosixPath(target), reader_parent / target]:
        normalized_text = posixpath.normpath(candidate.as_posix())
        normalized = pathlib.PurePosixPath(normalized_text)
        if normalized.is_absolute() or normalized == pathlib.PurePosixPath("..") or normalized_text.startswith("../"):
            continue
        # Preserve component order until symlinks have been resolved.
        candidates.add(candidate.as_posix())
    return candidates


def has_symlink_prefix(candidate: str, symlinks: t.Set[str]) -> bool:
    parts = pathlib.PurePosixPath(candidate).parts
    return any(
        posixpath.normpath("/".join(parts[:index])) in symlinks
        for index in range(1, len(parts) + 1)
    )


def literal_doc_paths(
    root: pathlib.Path,
    reader: str,
    contents: str,
    available: "t.Set[str] | None" = None,
    symlinks: "t.Set[str] | None" = None,
) -> t.Set[str]:
    pins = set(DOC_PATH.findall(contents))
    for match in QUOTED_PATH.finditer(contents):
        token = match.group(1).split("#", 1)[0]
        if re.search(r"[{}$()\\]", token):
            continue
        if available is not None:
            candidates = repository_path_candidates(reader, token)
            for candidate in candidates:
                is_symlink = symlinks is not None and has_symlink_prefix(candidate, symlinks)
                if not token.endswith(".md") and not is_symlink:
                    continue
                if is_symlink:
                    # Symlink paths stay raw: resolution walks their components in order.
                    pins.add(candidate)
                    continue
                # Without a symlink prefix the text-normalized path is the real path.
                normalized_candidate = posixpath.normpath(candidate)
                if token.startswith("docs/") or normalized_candidate in available:
                    pins.add(normalized_candidate)
            continue
        if not token.endswith(".md"):
            continue
        candidates = [root / token]
        if not token.startswith("docs/"):
            candidates.append(root / pathlib.PurePosixPath(reader).parent / token)
        for candidate in candidates:
            if candidate.is_file() or token.startswith("docs/"):
                pins.update(repository_doc_paths(root, candidate))
    return pins


def agent_named_paths(reader: str, contents: str) -> t.Set[str]:
    tokens = set(REPOSITORY_PATH.findall(contents))
    tokens.update(BARE_REPOSITORY_FILE.findall(contents))
    tokens.update(match.group(1) for match in QUOTED_PATH.finditer(contents))
    paths: t.Set[str] = set()
    for token in tokens:
        paths.update(repository_path_candidates(reader, token))
    return paths


def tree_files(root: pathlib.Path, revision: "str | None") -> t.List[str]:
    if revision is None:
        return tracked_files(root)
    return [
        os.fsdecode(path)
        for path in git_output(root, "ls-tree", "-r", "--name-only", revision, "--").split(b"\n")
        if path
    ]


def tree_file_bytes(root: pathlib.Path, revision: "str | None", path: str) -> bytes:
    if revision is None:
        return (root / path).read_bytes()
    return git_output(root, "show", f"{revision}:{path}")


def revision_symlink_targets(root: pathlib.Path, revision: str) -> t.Dict[str, str]:
    # Resolve against this revision, not the checkout: the base and head may
    # give the same alias different targets, and both are classifier inputs.
    symlinks: t.Dict[str, str] = {}
    for entry in git_output(root, "ls-tree", "-r", "-z", revision, "--").split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        if metadata.split(b" ", 1)[0] == b"120000":
            alias = os.fsdecode(path)
            symlinks[alias] = os.fsdecode(tree_file_bytes(root, revision, alias))
    return symlinks


def resolve_revision_path(candidate: str, symlinks: t.Dict[str, str]) -> t.Tuple[str, t.Set[str]]:
    # Walk before normalizing: collapsing alias/.. lexically changes its target.
    pending = list(pathlib.PurePosixPath(candidate).parts)
    resolved: t.List[str] = []
    aliases: t.Set[str] = set()
    if pathlib.PurePosixPath(candidate).is_absolute():
        raise ValueError(f"pinned path leaves repository: {candidate}")
    while pending:
        component = pending.pop(0)
        if component == "..":
            if not resolved:
                raise ValueError(f"pinned path leaves repository: {candidate}")
            resolved.pop()
            continue
        resolved.append(component)
        alias = "/".join(resolved)
        if alias not in symlinks:
            continue
        if alias in aliases:
            raise ValueError(f"cyclic pinned symlink: {alias}")
        if pending and pending[0] == "..":
            raise ValueError(f"parent traversal after symlink: {candidate}")
        aliases.add(alias)
        target = pathlib.PurePosixPath(symlinks[alias])
        if target.is_absolute():
            raise ValueError(f"pinned symlink leaves repository: {alias}")
        resolved.pop()
        pending = list(target.parts) + pending
    return "/".join(resolved), aliases


def revision_symlink_pins(
    root: pathlib.Path, revision: str, pins: t.Set[str], symlinks: t.Dict[str, str]
) -> t.Set[str]:
    tracked = set(tree_files(root, revision))
    resolved_pins = set(pins)
    for pin in pins:
        resolved, aliases = resolve_revision_path(pin, symlinks)
        resolved_pins.add(resolved)
        resolved_pins.update(aliases)
        if any(marker in pin or marker in resolved for marker in ["*", "?"]):
            resolved_pins.update(
                path for path in tracked
                if pathlib.PurePosixPath(path).match(pin)
                or pathlib.PurePosixPath(path).match(resolved)
            )
    return resolved_pins


def pinned_docs(root: pathlib.Path, revision: "str | None" = None) -> t.List[str]:
    tracked = tree_files(root, revision)
    symlinks = revision_symlink_targets(root, revision) if revision is not None else None
    available = set(tracked) if revision is not None else None
    symlink_paths = set(symlinks) if symlinks is not None else None
    pins: t.Set[str] = set()
    for path in tracked:
        agent_doc = pathlib.PurePosixPath(path).name in AGENT_DOC_NAMES
        # Scan all tracked inputs in the owning roots: CSS, Markdown used by
        # tooling, extensionless scripts and future formats can name doc inputs.
        # A file-type whitelist would silently miss readers added later.
        code_reader = path.split("/", 1)[0] in CODE_ROOTS
        if not agent_doc and not code_reader:
            continue
        if agent_doc:
            pins.add(path)
        contents = tree_file_bytes(root, revision, path).decode("utf-8", errors="ignore")
        pins.update(literal_doc_paths(root, path, contents, available, symlink_paths))
        if agent_doc:
            # Architecture lint opens linked targets and inline repository paths
            # while resolving agent instructions. Pin every named path, even if
            # it is absent in this tree, because deletion is a code change.
            pins.update(agent_named_paths(path, contents))
    if revision is not None:
        # Keep glob patterns until after symlink expansion; guide/*.md has no
        # matching blob before guide is resolved to its target directory.
        return sorted(revision_symlink_pins(root, revision, pins, symlinks or {}))
    expanded: t.Set[str] = set()
    for pin in pins:
        if "*" in pin or "?" in pin:
            expanded.update(
                path for path in tracked if pathlib.PurePosixPath(path).match(pin)
            )
        else:
            expanded.add(pin)
    return sorted(expanded)


def complete_revision(revision: str) -> bool:
    return bool(re.fullmatch(r"[0-9a-fA-F]{40,64}", revision))


def classify_diff_paths(
    root: pathlib.Path, event: str, base: str, head: str
) -> t.Tuple[str, t.List[str]]:
    """Select and read one trusted pull-request range."""
    if not complete_revision(head):
        raise ValueError("head must be a complete commit ID")
    if event == "pull_request":
        if not complete_revision(base):
            raise ValueError("PR base must be a complete commit ID")
        diff_base = git_output(root, "merge-base", base, head).decode().strip()
    else:
        return "", []
    changed = [
        os.fsdecode(path)
        for path in git_output(
            root, "diff", "--name-only", "-z", "--no-renames", diff_base, head, "--"
        ).split(b"\0")
        if path
    ]
    return diff_base, changed


def deleted_paths(root: pathlib.Path, diff_base: str, head: str) -> t.Set[str]:
    return {
        os.fsdecode(path)
        for path in git_output(
            root, "diff", "--name-only", "--diff-filter=D", "-z", "--no-renames", diff_base, head, "--"
        ).split(b"\0")
        if path
    }


def scope_for_paths(
    changed: t.List[str], pins: t.Set[str], deleted: t.Set[str]
) -> t.Tuple[Scope, t.List[str], t.List[str]]:
    code_files = [
        path
        for path in changed
        if path in deleted and not path.startswith("docs/")
        or not is_doc(path)
        or path in pins
        or pathlib.PurePosixPath(path).name in AGENT_DOC_NAMES
    ]
    doc_files = [path for path in changed if is_doc(path) and path not in pins]
    if not changed or code_files:
        scope: Scope = "full"
    else:
        scope = "docs"
    return scope, code_files, doc_files


class ChangesArguments(argparse.Namespace):
    command: str
    root: pathlib.Path
    event: str
    base: str
    head: str
    receipt: "pathlib.Path | None"
    github_output: "pathlib.Path | None"

    def __init__(self) -> None:
        super().__init__()
        self.command = ""
        self.root = pathlib.Path.cwd()
        self.event = ""
        self.base = ""
        self.head = ""
        self.receipt = None
        self.github_output = None


def full_result(event: str, head: str, reason: str) -> t.Dict[str, object]:
    return {
        "scope": "full",
        "event": event,
        "head": head,
        "changed_files": [],
        "pinned_docs": [],
        "code_files": [],
        "doc_files": [],
        "reason": reason,
    }


def classify_changes(
    root: pathlib.Path, arguments: ChangesArguments
) -> t.Dict[str, object]:
    event, base, head = arguments.event, arguments.base, arguments.head
    if event != "pull_request":
        return full_result(event, head, "non-PR events keep full CI")
    diff_base, changed = classify_diff_paths(root, event, base, head)
    pins = sorted(set(pinned_docs(root, diff_base)) | set(pinned_docs(root, head)))
    deleted = deleted_paths(root, diff_base, head)
    scope, code_files, doc_files = scope_for_paths(changed, set(pins), deleted)
    return {
        "scope": scope,
        "event": event,
        "diff_base": diff_base,
        "head": head,
        "changed_files": changed,
        "pinned_docs": pins,
        "code_files": code_files,
        "doc_files": doc_files,
        "reason": {
            "docs": "only unpinned documentation changed",
            "full": "empty diff or code/contract input changed",
        }[scope],
    }


def write_scope_output(path: pathlib.Path, scope: str) -> None:
    with path.open("a", encoding="utf-8") as output:
        output.write(f"scope={scope}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["pinned", "classify"])
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--event", default="")
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    parser.add_argument("--receipt", type=pathlib.Path)
    parser.add_argument("--github-output", type=pathlib.Path)
    args = parser.parse_args(namespace=ChangesArguments())
    root = args.root.resolve()
    try:
        if args.command == "pinned":
            print("\n".join(pinned_docs(root)))
            return 0
        result = classify_changes(root, args)
        if args.receipt is None:
            raise ValueError("classify requires --receipt")
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        changed_files = result["changed_files"]
        pinned_paths = result["pinned_docs"]
        scope = result["scope"]
        if not isinstance(changed_files, list) or not isinstance(pinned_paths, list):
            raise ValueError("classification receipt has invalid path lists")
        if not isinstance(scope, str) or scope not in {"docs", "full"}:
            raise ValueError("classification receipt has invalid scope")
        if args.github_output is not None:
            write_scope_output(args.github_output, scope)
        print(
            f"change-scope classification: scope={scope} changed_files={len(changed_files)} pinned_docs={len(pinned_paths)}"
        )
        print(json.dumps(result, ensure_ascii=True))
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        # A failed changes job must never make dependent required checks skip.
        if args.github_output is not None:
            write_scope_output(args.github_output, "full")
        print(f"change-scope classification failed; run full CI: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
