#!/usr/bin/env python3
"""Check local Markdown links in changed documentation without network access."""

import argparse
import html
import os
import pathlib
import re
import sys
import typing as t
import urllib.parse


def prose_lines(contents: str) -> t.List[t.Tuple[int, str]]:
    lines: t.List[t.Tuple[int, str]] = []
    fence: str | None = None
    for number, line in enumerate(contents.splitlines(), 1):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence is not None:
            if (
                marker
                and marker.group(1)[0] == fence[0]
                and len(marker.group(1)) >= len(fence)
            ):
                fence = None
            continue
        if marker:
            fence = marker.group(1)
            continue
        if line.startswith("    ") or line.startswith("\t"):
            continue
        lines.append((number, line))
    return lines


def heading_slug(text: str) -> str:
    rendered = html.unescape(re.sub(r"<[^>]*>", "", text))
    rendered = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", rendered)
    return "".join(
        "-" if char == " " else char
        for char in rendered.lower()
        if char.isalnum() or char in " -_"
    )


def markdown_anchors(contents: str) -> t.Set[str]:
    result: t.Set[str] = set()
    counts: t.Dict[str, int] = {}
    lines = prose_lines(contents)
    for index, (_, line) in enumerate(lines):
        result.update(
            re.findall(
                r"""<(?:a|[a-z][\w-]*)\b[^>]*\b(?:id|name)=["']([^"']+)["']""",
                line,
                flags=re.I,
            )
        )
        heading = re.match(r"^ {0,3}#{1,6}(?:\s+|$)(.*?)\s*#*\s*$", line)
        text: str | None = heading.group(1) if heading else None
        if (
            text is None
            and index + 1 < len(lines)
            and re.fullmatch(r" {0,3}(?:=+|-+)\s*", lines[index + 1][1])
            and line.strip()
        ):
            text = line.strip()
        if text is not None:
            slug = heading_slug(text)
            occurrence = counts.get(slug, 0)
            result.add(slug if occurrence == 0 else f"{slug}-{occurrence}")
            counts[slug] = occurrence + 1
    return result


def local_link_destinations(contents: str) -> t.List[t.Tuple[int, str]]:
    references: t.List[t.Tuple[int, str]] = []
    # Definitions cover both full and collapsed reference links, including
    # definitions that are reused on several lines.
    for number, line in prose_lines(contents):
        line = re.sub(r"(`+).*?\1", "", line)
        definition = re.match(r"^ {0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)", line)
        if definition:
            references.append((number, definition.group(1).strip("<>")))
        # Balanced parentheses support relative paths such as diagram(1).svg.
        for link in re.finditer(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(", line):
            start = link.end()
            end = start
            depth = 1
            while end < len(line) and depth:
                if line[end] == "\\":
                    end += 2
                    continue
                if line[end] == "(":
                    depth += 1
                elif line[end] == ")":
                    depth -= 1
                if depth:
                    end += 1
            if depth:
                continue
            value = line[start:end].strip()
            if value.startswith("<") and ">" in value:
                target = value[1 : value.index(">")]
            else:
                target = re.split(r"""\s+["']""", value, maxsplit=1)[0]
            references.append((number, re.sub(r"\\([()])", r"\1", target)))
    return references


def check_local_links(root: pathlib.Path, changed: t.List[str]) -> t.List[str]:
    problems: t.List[str] = []
    cached: t.Dict[pathlib.Path, t.Set[str]] = {}
    for path in changed:
        document = root / path
        if document.suffix.lower() != ".md" or not document.exists():
            continue  # Deletions and non-Markdown doc assets have no links to read.
        contents = document.read_text(encoding="utf-8")
        for line, written in local_link_destinations(contents):
            parsed = urllib.parse.urlsplit(written)
            if parsed.scheme or parsed.netloc:
                continue  # Never request an external target.
            target = (
                (document.parent / urllib.parse.unquote(parsed.path)).resolve()
                if parsed.path
                else document.resolve()
            )
            try:
                target.relative_to(root)
            except ValueError:
                problems.append(
                    f"{path}:{line}: local link leaves the repository: {written}"
                )
                continue
            if not target.exists():
                problems.append(f"{path}:{line}: missing local target: {written}")
                continue
            if parsed.fragment and target.is_file():
                target_contents = target.read_text(encoding="utf-8")
                anchor = urllib.parse.unquote(parsed.fragment)
                if target.suffix.lower() == ".md":
                    if target not in cached:
                        cached[target] = markdown_anchors(target_contents)
                    anchor_exists = anchor in cached[target]
                else:
                    explicit = set(
                        re.findall(r"\bid=[\"']([^\"']+)[\"']", target_contents)
                    )
                    source_lines = re.fullmatch(r"L(\d+)(?:-L(\d+))?", anchor)
                    anchor_exists = anchor in explicit
                    if source_lines:
                        first = int(source_lines.group(1))
                        last = int(source_lines.group(2) or first)
                        anchor_exists = (
                            1 <= first <= last <= len(target_contents.splitlines())
                        )
                if not anchor_exists:
                    problems.append(
                        f"{path}:{line}: missing anchor #{anchor} in {parsed.path or path}"
                    )
    return problems


class LinkArguments(argparse.Namespace):
    root: pathlib.Path
    changed_files: pathlib.Path

    def __init__(self) -> None:
        super().__init__()
        self.root = pathlib.Path.cwd()
        self.changed_files = pathlib.Path()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--changed-files", type=pathlib.Path, required=True)
    args = parser.parse_args(namespace=LinkArguments())
    try:
        changed = [
            os.fsdecode(path)
            for path in args.changed_files.read_bytes().split(b"\0")
            if path
        ]
        fixture_root = pathlib.PurePosixPath(
            pathlib.Path(__file__)
            .with_name("architecture-doc-fixture-root.txt")
            .read_text(encoding="utf-8")
            .strip()
        )
        if (
            not fixture_root.parts
            or fixture_root.is_absolute()
            or ".." in fixture_root.parts
        ):
            raise ValueError(
                "architecture doc fixture root must be a nonempty relative path"
            )
        # These documents intentionally contain broken links for lint-rule tests.
        # Classification still sees them; only this document gate exempts them.
        changed = [
            path
            for path in changed
            if fixture_root not in pathlib.PurePosixPath(path).parents
        ]
        markdown = [
            path
            for path in changed
            if (args.root / path).suffix.lower() == ".md"
            and (args.root / path).is_file()
        ]
        if not markdown:
            print(
                "changed-doc link check: no changed Markdown documents; nothing to check"
            )
            return 0
        problems = check_local_links(args.root.resolve(), changed)
        if problems:
            print("\n".join(problems), file=sys.stderr)
            return 1
        print(
            f"changed-doc link check: {len(changed)} changed paths; all local links and Markdown anchors resolve"
        )
        return 0
    except (OSError, ValueError) as error:
        print(f"changed-doc link check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
