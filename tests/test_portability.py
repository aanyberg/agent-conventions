"""Cross-agent portability: one copy of each skill must work in every agent.

This repo ships exactly one copy of every skill. That is only sound while each
`SKILL.md` stays inside the Agent Skills specification (agentskills.io) and free
of anything a single vendor provides. The moment a skill reaches for something
only one agent has, the single copy stops being portable and the install story
silently forks per agent — which is the whole thing the root layout exists to
avoid.

These rules are deliberately narrow, because the obvious version of them is
useless. Naming a vendor directory as an example of where *not* to put something
is portable prose, not coupling: `task-workflow` names `~/.claude` and
`~/.copilot` side by side for exactly that reason, and must keep passing. What
actually breaks portability is a skill that *depends* on one vendor — its
interpolated variables, its component directories, its tool names, its
instruction filename.

Agent bodies are held to the same prose rules. Agent *frontmatter* is
Claude-specific by nature and is checked in `test_agents.py`; the body is the
part a future per-agent emitter has to carry across unchanged.
"""

from __future__ import annotations

import re

import pytest

from conftest import SPEC_FRONTMATTER_KEYS

# `${CLAUDE_PLUGIN_ROOT}` and friends resolve only inside Claude Code. Anywhere
# else they stay literal text, so a path built from one silently points nowhere.
VENDOR_VARIABLE = re.compile(r"\$\{?(?:CLAUDE|CODEX|CURSOR|COPILOT|GEMINI)_[A-Z_]+\}?")

# Component directories owned by one agent. `.agents/` is deliberately absent:
# it is the cross-vendor convention every major agent reads, so `.agents/skills/`
# is the portable choice rather than a violation.
VENDOR_COMPONENT_DIR = re.compile(
    r"\.(?:claude|codex|cursor|opencode|gemini|copilot|windsurf|github)/"
    r"(?:skills|agents|commands|rules|hooks|prompts)/"
)

# Instruction files owned by one vendor. `AGENTS.md` is the portable spelling and
# is read by 30+ agents; the rest are each read by exactly one.
VENDOR_INSTRUCTION_FILE = re.compile(
    r"\b(?:CLAUDE\.md|GEMINI\.md|QWEN\.md|copilot-instructions\.md|\.cursorrules)\b"
)

# Tool names from Claude Code's vocabulary. Other agents expose different tools
# under different names, so instructing an agent to use one by name is a
# single-vendor dependency. Matched only in unambiguous forms — bare "Read" or
# "Write" are ordinary English and are left alone.
CLAUDE_TOOLS = (
    "AskUserQuestion|Bash|Edit|Glob|Grep|NotebookEdit|Read|Skill|SlashCommand"
    "|Task|TodoWrite|WebFetch|WebSearch|Write"
)
TOOL_PHRASE = re.compile(rf"\b(?:{CLAUDE_TOOLS}) tools?\b")
TOOL_BACKTICKED = re.compile(
    r"`(?:AskUserQuestion|NotebookEdit|SlashCommand|TodoWrite|WebFetch|WebSearch)`"
)

# The spec recommends keeping SKILL.md under 500 lines and moving detail into
# `references/`, because the whole body loads once a skill activates. Agents with
# tighter context budgets than Claude's are the ones that suffer first.
MAX_BODY_LINES = 500

# Spec cap on the optional `compatibility` field.
MAX_COMPATIBILITY = 500

# Spec cap on `name`.
MAX_NAME = 64


def _hits(pattern: re.Pattern[str], text: str) -> list[str]:
    """Distinct matches, in source order, for a readable failure message."""
    seen: dict[str, None] = {}
    for match in pattern.findall(text):
        seen.setdefault(match, None)
    return list(seen)


# ---------------------------------------------------------------------------
# Specification conformance
# ---------------------------------------------------------------------------

def test_skill_frontmatter_stays_within_the_spec(skill):
    outside = set(skill.frontmatter) - SPEC_FRONTMATTER_KEYS
    assert not outside, (
        f"{skill.rel}: frontmatter key(s) {sorted(outside)} are not in the Agent Skills "
        f"spec; a conformant loader in another agent may ignore or reject the file"
    )


def test_skill_name_fits_the_spec_limit(skill):
    name = str(skill.frontmatter.get("name", ""))
    assert len(name) <= MAX_NAME, (
        f"{skill.rel}: name is {len(name)} chars, over the spec limit of {MAX_NAME}"
    )


def test_skill_metadata_is_a_string_map(skill):
    """The spec types `metadata` as string → string; YAML will happily give ints."""
    metadata = skill.frontmatter.get("metadata")
    if metadata is None:
        return
    assert isinstance(metadata, dict), f"{skill.rel}: metadata must be a mapping"
    bad = [k for k, v in metadata.items() if not isinstance(k, str) or not isinstance(v, str)]
    assert not bad, (
        f"{skill.rel}: metadata key(s) {sorted(bad)} are not string → string; "
        f"quote the value (e.g. version: \"1.0\", not version: 1.0)"
    )


def test_skill_compatibility_fits_the_spec_limit(skill):
    value = skill.frontmatter.get("compatibility")
    if value is None:
        return
    assert 1 <= len(str(value)) <= MAX_COMPATIBILITY, (
        f"{skill.rel}: compatibility is {len(str(value))} chars, outside 1..{MAX_COMPATIBILITY}"
    )


def test_skill_avoids_experimental_allowed_tools(skill):
    """`allowed-tools` is spec-optional and explicitly experimental.

    Support varies between agents — Kiro CLI and Zencoder ignore it entirely —
    and the tool vocabulary it names differs per vendor, so a skill that relies
    on it is no longer one-copy portable. Adding it is a deliberate trade, not
    something to acquire by accident.
    """
    assert "allowed-tools" not in skill.frontmatter, (
        f"{skill.rel}: 'allowed-tools' is experimental and not honoured by every agent; "
        f"if a skill genuinely needs it, add it to this test's exemptions with a reason"
    )


# ---------------------------------------------------------------------------
# Vendor coupling — skills and agent bodies alike
# ---------------------------------------------------------------------------

def test_skill_interpolates_no_vendor_variable(skill):
    found = _hits(VENDOR_VARIABLE, skill.body)
    assert not found, (
        f"{skill.rel}: {found} resolve only inside one agent; elsewhere they stay "
        f"literal and any path built from them points nowhere"
    )


def test_skill_references_no_vendor_component_directory(skill):
    found = _hits(VENDOR_COMPONENT_DIR, skill.body)
    assert not found, (
        f"{skill.rel}: {found} is one agent's component directory; use the "
        f"cross-vendor '.agents/' convention or a path relative to the project root"
    )


def test_skill_references_no_vendor_instruction_file(skill):
    found = _hits(VENDOR_INSTRUCTION_FILE, skill.body)
    assert not found, (
        f"{skill.rel}: {found} is read by one agent; AGENTS.md is the portable spelling"
    )


def test_skill_names_no_vendor_specific_tool(skill):
    found = _hits(TOOL_PHRASE, skill.body) + _hits(TOOL_BACKTICKED, skill.body)
    assert not found, (
        f"{skill.rel}: {found} names a tool from one agent's vocabulary; describe the "
        f"capability instead (\"search the repo\", not \"use Grep\")"
    )


def test_agent_body_interpolates_no_vendor_variable(agent):
    found = _hits(VENDOR_VARIABLE, agent.body)
    assert not found, f"{agent.rel}: {found} resolve only inside one agent"


def test_agent_body_references_no_vendor_component_directory(agent):
    found = _hits(VENDOR_COMPONENT_DIR, agent.body)
    assert not found, (
        f"{agent.rel}: {found} is one agent's component directory; the body has to survive "
        f"being emitted for OpenCode, Copilot and Antigravity unchanged"
    )


def test_agent_body_references_no_vendor_instruction_file(agent):
    found = _hits(VENDOR_INSTRUCTION_FILE, agent.body)
    assert not found, f"{agent.rel}: {found} is read by one agent; AGENTS.md is portable"


# ---------------------------------------------------------------------------
# Progressive disclosure
# ---------------------------------------------------------------------------

def test_skill_body_fits_the_progressive_disclosure_budget(skill):
    lines = len(skill.body.splitlines())
    assert lines <= MAX_BODY_LINES, (
        f"{skill.rel}: body is {lines} lines, over the {MAX_BODY_LINES} the spec "
        f"recommends; the whole body loads on activation, so move detail into "
        f"references/ where agents can load it only when needed"
    )


# ---------------------------------------------------------------------------
# The rules themselves
#
# Every rule above passes today, which on its own proves nothing: a pattern that
# matches nothing passes identically to one that works. These pin each rule to a
# sample it must catch and a sample it must not, so a regex that rots into
# uselessness fails here rather than going quietly green forever.
# ---------------------------------------------------------------------------

CAUGHT = [
    (VENDOR_VARIABLE, "run ${CLAUDE_PLUGIN_ROOT}/scripts/x.sh"),
    (VENDOR_VARIABLE, "$CLAUDE_PROJECT_DIR/notes"),
    (VENDOR_COMPONENT_DIR, "drop it in .claude/skills/foo/"),
    (VENDOR_COMPONENT_DIR, "see .github/prompts/review.md"),
    (VENDOR_COMPONENT_DIR, "add a rule under .cursor/rules/"),
    (VENDOR_INSTRUCTION_FILE, "append it to CLAUDE.md"),
    (VENDOR_INSTRUCTION_FILE, "documented in copilot-instructions.md"),
    (TOOL_PHRASE, "use the Grep tool to find it"),
    (TOOL_PHRASE, "dispatch with the Task tool"),
    (TOOL_PHRASE, "prefer the Read and Write tools"),
    (TOOL_BACKTICKED, "call `WebFetch` on the URL"),
]

# Prose that must keep passing. The first two are the live case from
# task-workflow: naming vendor home directories as somewhere NOT to write is
# portable guidance, and a rule that flags it would be deleted within a week.
IGNORED = [
    (VENDOR_COMPONENT_DIR, "never in a global tool directory (e.g. `~/.claude`, `~/.copilot`)"),
    (VENDOR_VARIABLE, "never in a global tool directory (e.g. `~/.claude`, `~/.copilot`)"),
    (VENDOR_COMPONENT_DIR, "the portable location is .agents/skills/<name>/"),
    (VENDOR_INSTRUCTION_FILE, "patterns from AGENTS.md apply here"),
    (VENDOR_COMPONENT_DIR, "workflows live in .github/workflows/"),
    (TOOL_PHRASE, "write the task file before any code"),
    (TOOL_PHRASE, "read the policy first, then edit"),
    (TOOL_PHRASE, "this is a read-only review task"),
    (TOOL_BACKTICKED, "the `Read` step is implicit"),
]


@pytest.mark.parametrize("pattern, sample", CAUGHT, ids=[s for _, s in CAUGHT])
def test_rule_catches_a_real_violation(pattern, sample):
    assert pattern.search(sample), f"{pattern.pattern} failed to catch: {sample!r}"


@pytest.mark.parametrize("pattern, sample", IGNORED, ids=[s for _, s in IGNORED])
def test_rule_ignores_portable_prose(pattern, sample):
    assert not pattern.search(sample), (
        f"{pattern.pattern} false-positives on portable prose: {sample!r}"
    )
