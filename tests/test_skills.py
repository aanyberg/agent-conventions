"""Skill frontmatter is the loader's contract — a typo here silently drops a skill."""

from __future__ import annotations

import re
from collections import Counter

from conftest import parse_frontmatter, repo_root, skill_files

NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

# Keys Claude Code actually reads from SKILL.md frontmatter. Anything else is
# silently ignored at load time, so an unknown key is dead configuration.
ALLOWED_KEYS = {"name", "description", "allowed-tools", "license", "metadata", "version"}

# Descriptions longer than this are truncated when the skill list is built,
# which cuts off the trigger phrases at the end and hurts routing.
MAX_DESCRIPTION = 1024

VALID_TOOLS = {
    "AskUserQuestion", "Bash", "Edit", "Glob", "Grep", "NotebookEdit", "Read",
    "Skill", "SlashCommand", "Task", "TodoWrite", "WebFetch", "WebSearch", "Write",
}


def test_every_skill_directory_has_a_skill_file():
    missing = [
        str(d.relative_to(repo_root()))
        for d in sorted(repo_root().glob("skills/*"))
        if d.is_dir() and not (d / "SKILL.md").is_file()
    ]
    assert not missing, f"skill directories without a SKILL.md: {missing}"


def test_skill_has_name_and_description(skill):
    assert "name" in skill.frontmatter, f"{skill.rel}: frontmatter has no 'name'"
    assert "description" in skill.frontmatter, f"{skill.rel}: frontmatter has no 'description'"
    assert str(skill.frontmatter["description"]).strip(), f"{skill.rel}: description is empty"


def test_skill_name_matches_directory(skill):
    expected = skill.path.parent.name
    assert skill.frontmatter.get("name") == expected, (
        f"{skill.rel}: name {skill.frontmatter.get('name')!r} must match directory {expected!r}"
    )


def test_skill_name_is_kebab_case(skill):
    name = str(skill.frontmatter.get("name", ""))
    assert NAME.match(name), f"{skill.rel}: name {name!r} must be lowercase kebab-case"


def test_skill_description_fits_the_loader_budget(skill):
    length = len(str(skill.frontmatter["description"]))
    assert length <= MAX_DESCRIPTION, (
        f"{skill.rel}: description is {length} chars, over the {MAX_DESCRIPTION} limit; "
        "trigger phrases at the end would be truncated"
    )


def test_skill_has_no_unknown_frontmatter_keys(skill):
    unknown = set(skill.frontmatter) - ALLOWED_KEYS
    assert not unknown, (
        f"{skill.rel}: unrecognised frontmatter key(s) {sorted(unknown)}; "
        f"Claude Code ignores these, so they are dead configuration "
        f"(tool restrictions go in 'allowed-tools')"
    )


def test_skill_allowed_tools_are_real_tools(skill):
    tools = skill.frontmatter.get("allowed-tools")
    if tools is None:
        return
    if isinstance(tools, str):
        tools = [t.strip() for t in tools.split(",") if t.strip()]
    unknown = [t for t in tools if t not in VALID_TOOLS and not str(t).startswith("mcp__")]
    assert not unknown, f"{skill.rel}: unknown tool name(s) {unknown}"


def test_skill_names_are_unique_across_plugins():
    names = [parse_frontmatter(p).frontmatter.get("name") for p in skill_files()]
    duplicates = [n for n, count in Counter(names).items() if count > 1]
    assert not duplicates, f"duplicate skill names across plugins: {duplicates}"


def test_skill_body_is_not_empty(skill):
    assert len(skill.body.strip()) > 100, f"{skill.rel}: body looks like a stub"
