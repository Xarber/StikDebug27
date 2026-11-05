#!/usr/bin/env python3
"""Generate release notes from the actual commit range; never execute commit text."""
import argparse
import re
import subprocess
from pathlib import Path

GROUPS = {"feat": "Features", "fix": "Fixes & Improvements", "perf": "Fixes & Improvements", "revert": "Fixes & Improvements"}
CONVENTIONAL = re.compile(r"^(feat|fix|perf|refactor|docs|test|ci|build|chore|revert)(?:\(([^)]+)\))?(!)?:\s*(.+)$")

def generate(repository, base="", head="HEAD"):
    revision = f"{base}..{head}" if base else head
    output = subprocess.check_output(["git", "log", "--no-merges", "--format=%H%x00%s", "--end-of-options", revision], text=True)
    groups = {}
    for line in output.splitlines():
        sha, subject = line.split("\0", 1)
        match = CONVENTIONAL.match(subject)
        title = match.group(4) if match else subject
        scope = match.group(2) if match else None
        group = GROUPS.get(match.group(1), "Maintenance") if match else "Other updates"
        if match and match.group(3):
            group = "Breaking changes"
        # Plain titles are rendered as text, without permitting embedded HTML.
        title = title.replace("<", "&lt;").replace(">", "&gt;")
        label = f"**{scope}:** {title}" if scope else title
        groups.setdefault(group, []).append(f"- {label} ([{sha[:7]}](https://github.com/{repository}/commit/{sha}))")
    sections = []
    for group in ["Breaking changes", "Features", "Fixes & Improvements", "Maintenance", "Other updates"]:
        if group in groups:
            sections.append("## " + group + "\n\n" + "\n".join(groups[group]))
    return "\n\n".join(sections) + "\n" if sections else "No new commits since the previous release.\n"

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--output", default="RELEASE_NOTES.md")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("Invalid repository")
    Path(args.output).write_text(generate(args.repository, args.base), encoding="utf-8")
