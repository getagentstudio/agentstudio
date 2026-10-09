#!/usr/bin/env python3
"""Classify changed files conservatively; a scanner failure keeps full CI."""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import typing as t
import urllib.parse

CODE_ROOTS = {"Tests", "Tools", "BridgeWeb", "web", "scripts"}
AGENT_DOC_NAMES = {"AGENTS.md", "CLAUDE.md"}
DOC_PATH = re.compile(r"\bdocs/[\w./+*?%-]+\.[\w]+\b")
QUOTED_PATH = re.compile(r"[\"'`]([^\"'`\n]+)[\"'`]")
Scope = t.Literal["docs", "website", "full"]


class UnsafePushRange(ValueError):
    """A push range cannot be trusted for selective CI."""


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


def is_website(path: str) -> bool:
    return path.startswith("web/")


def is_doc(path: str) -> bool:
    # Tests remain code even when their fixture happens to be Markdown. Website
    # paths are classified separately, including website Markdown.
    return not is_website(path) and not path.startswith("Tests/") and (
        path.startswith("docs/") or path.endswith(".md")
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


def literal_doc_paths(root: pathlib.Path, reader: str, contents: str) -> t.Set[str]:
    pins = set(DOC_PATH.findall(contents))
    for match in QUOTED_PATH.finditer(contents):
        token = match.group(1).split("#", 1)[0]
        if not token.endswith(".md") or re.search(r"[{}$()\\]", token):
            continue
        candidates = [root / token]
        if not token.startswith("docs/"):
            candidates.append(root / pathlib.PurePosixPath(reader).parent / token)
        for candidate in candidates:
            if candidate.is_file() or token.startswith("docs/"):
                pins.update(repository_doc_paths(root, candidate))
    return pins


def pinned_docs(root: pathlib.Path) -> t.List[str]:
    tracked = tracked_files(root)
    pins: t.Set[str] = set()
    for path in tracked:
        file = root / path
        agent_doc = pathlib.PurePosixPath(path).name in AGENT_DOC_NAMES
        # Scan all tracked inputs in the owning roots: CSS, Markdown used by
        # tooling, extensionless scripts and future formats can name doc inputs.
        # A file-type whitelist would silently miss readers added later.
        code_reader = path.split("/", 1)[0] in CODE_ROOTS
        if not agent_doc and not code_reader:
            continue
        if not file.is_file():
            raise OSError(f"tracked classifier input is missing: {path}")
        if agent_doc:
            pins.add(path)
        contents = file.read_bytes().decode("utf-8", errors="ignore")
        pins.update(literal_doc_paths(root, path, contents))
        if agent_doc:
            # Architecture lint opens linked targets and inline repository paths
            # while resolving agent instructions; those documents are code inputs.
            for token in re.findall(r"[\w./+%-]+\.md(?:#[\w-]+)?", contents):
                target = urllib.parse.unquote(token.split("#", 1)[0])
                for candidate in [file.parent / target, root / target]:
                    if candidate.is_file():
                        pins.update(repository_doc_paths(root, candidate))
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
    """Select and read one trusted range for PR and push events."""
    if not complete_revision(head):
        raise ValueError("head must be a complete commit ID")
    if event == "pull_request":
        if not complete_revision(base):
            raise ValueError("PR base must be a complete commit ID")
        diff_base = git_output(root, "merge-base", base, head).decode().strip()
    elif event == "push":
        if not complete_revision(base):
            raise ValueError("push before must be a complete commit ID")
        if set(base) == {"0"}:
            raise UnsafePushRange("push before is the all-zero revision")
        try:
            git_output(root, "cat-file", "-e", f"{base}^{{commit}}")
            git_output(root, "cat-file", "-e", f"{head}^{{commit}}")
            git_output(root, "merge-base", "--is-ancestor", base, head)
        except subprocess.CalledProcessError as error:
            raise UnsafePushRange("push before is missing or is not an ancestor") from error
        diff_base = base
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


def scope_for_paths(
    changed: t.List[str], pins: t.Set[str]
) -> t.Tuple[Scope, t.List[str], t.List[str], t.List[str]]:
    code_files = [
        path
        for path in changed
        if (not is_doc(path) and not is_website(path))
        or path in pins
        or pathlib.PurePosixPath(path).name in AGENT_DOC_NAMES
    ]
    website_files = [path for path in changed if is_website(path) and path not in pins]
    doc_files = [path for path in changed if is_doc(path) and path not in pins]
    if not changed or code_files:
        scope: Scope = "full"
    elif website_files:
        scope = "website"
    else:
        scope = "docs"
    return scope, code_files, website_files, doc_files


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
        "website_files": [],
        "doc_files": [],
        "reason": reason,
    }


def classify_changes(
    root: pathlib.Path, arguments: ChangesArguments
) -> t.Dict[str, object]:
    event, base, head = arguments.event, arguments.base, arguments.head
    if event not in {"pull_request", "push"}:
        return full_result(event, head, "non-PR and non-push events keep full CI")
    try:
        diff_base, changed = classify_diff_paths(root, event, base, head)
    except UnsafePushRange as error:
        return full_result(event, head, str(error))
    pins = pinned_docs(root)
    scope, code_files, website_files, doc_files = scope_for_paths(changed, set(pins))
    return {
        "scope": scope,
        "event": event,
        "diff_base": diff_base,
        "head": head,
        "changed_files": changed,
        "pinned_docs": pins,
        "code_files": code_files,
        "website_files": website_files,
        "doc_files": doc_files,
        "reason": {
            "docs": "only unpinned documentation changed",
            "website": "only unpinned website and documentation changed",
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
        if not isinstance(scope, str) or scope not in {"docs", "website", "full"}:
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
