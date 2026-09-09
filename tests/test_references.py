"""Cross-references: broken links and stale skill names are silent instruction rot."""

from __future__ import annotations

import re

from conftest import agent_files, markdown_files, parse_frontmatter, repo_root, skill_files

# [text](target) where target is not an external URL, mailto, or bare anchor.
LINK = re.compile(r"\[[^\]]*\]\((?!https?://|mailto:|#)([^)\s]+)\)")

# Skills and agents are referenced in prose as **bolded-kebab-names**. Backticks
# are not treated as references — they carry filenames, flags, and config values.
REFERENCE = re.compile(r"\*\*([a-z0-9]+(?:-[a-z0-9]+)+)\*\*")

# Bolded hyphenated terms that are ordinary prose, not skill or agent names.
# Real skill and agent names are resolved from disk, so a rename still fails here.
NOT_A_REFERENCE = {
    "agent-conventions", "github-issues", "release-commit-only", "per-branch",
    "issue-number", "needs-discussion", "needs-human", "agent-safe",
    "in-review", "run-lock-issue", "planning-runs-dir", "short-kebab",
    "backlog-migration", "delete-tests", "skip-tests", "delete-or-skip-test",
    "commit-to-protected-branch", "package-lock", "pnpm-lock",
    "language-specific", "cross-language", "type-first", "read-only",
}


def _skill_names() -> set[str]:
    return {parse_frontmatter(p).frontmatter["name"] for p in skill_files()}


def _agent_names() -> set[str]:
    return {parse_frontmatter(p).frontmatter["name"] for p in agent_files()}


def test_relative_markdown_links_resolve(md_file):
    broken = []
    for target in LINK.findall(md_file.read_text(encoding="utf-8")):
        path = (md_file.parent / target.split("#", 1)[0]).resolve()
        if not path.exists():
            broken.append(target)
    assert not broken, f"{md_file.relative_to(repo_root())}: broken link(s) {broken}"


def test_shipped_scripts_are_executable_with_a_shebang():
    problems = []
    for script in sorted(repo_root().glob("skills/*/scripts/*.sh")):
        rel = script.relative_to(repo_root())
        if not script.stat().st_mode & 0o111:
            problems.append(f"{rel} (not executable)")
        if not script.read_text(encoding="utf-8").startswith("#!"):
            problems.append(f"{rel} (no shebang)")
    assert not problems, f"shipped scripts: {problems}"


def test_references_to_shipped_scripts_resolve():
    """A reference to a script this plugin ships must point at a real file.

    Paths that name no shipped script (e.g. `scripts/worktree-up.sh`) are
    consumer-repo policy values, not plugin assets, and are out of scope.
    """
    shipped = {p.name: p for p in repo_root().glob("skills/*/scripts/*.sh")}
    problems = []
    for path in skill_files() + agent_files():
        text = path.read_text(encoding="utf-8")
        for match in re.findall(r"[\w./-]*scripts/([A-Za-z0-9_.-]+\.sh)", text):
            if match not in shipped:
                continue
            owner = shipped[match].parents[1].name
            if path.parent.name != owner and f"**{owner}**" not in text and owner not in text:
                problems.append(
                    f"{path.relative_to(repo_root())} references scripts/{match} "
                    f"without naming its owning skill ({owner})"
                )
    assert not problems, problems


def test_skill_and_agent_names_referenced_in_prose_exist():
    """A rename must not leave dangling instructions in another skill's body."""
    known = _skill_names() | _agent_names() | NOT_A_REFERENCE
    dangling = [
        f"{path.relative_to(repo_root())}: **{token}**"
        for path in skill_files() + agent_files()
        for token in REFERENCE.findall(parse_frontmatter(path).body)
        if token not in known
    ]
    assert not dangling, f"prose references a skill or agent that does not exist: {dangling}"
