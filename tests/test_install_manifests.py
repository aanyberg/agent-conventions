"""Native install manifests — one repo, four ecosystems, one `skills/` directory.

Each supported ecosystem has its own way of saying "this repo is installable".
They are small static files that all point at the same top-level `skills/`, so
the cost is metadata rather than parallel copies of the content:

| File                            | Reaches                                          |
| ------------------------------- | ------------------------------------------------ |
| `plugin.json`                   | Agent Plugins v1: ChatGPT, Codex, Cursor,         |
|                                 | GitHub Copilot, Kiro, VS Code                     |
| `.claude-plugin/marketplace.json`| Claude Code — and Copilot CLI, which reads the   |
|                                 | same file, hence the `metadata` block below       |
| `.codex-plugin/plugin.json`     | Codex's own plugin system                         |
| `gemini-extension.json`         | `gemini extensions install`                       |

The risk they carry is drift: four files now state a version, and a release that
updates three of them ships an inconsistent set that no single tool can detect.
`test_every_manifest_declares_the_same_version` is the guard.

Component locations are deliberately *not* configurable here. Agent Plugins
fixes skills at `skills/` and forbids overriding it; Claude adds to the default
`skills/` scan; Gemini loads `skills/` on activation. Only Codex names a path,
and it names the same one.
"""

from __future__ import annotations

import json
import re

import pytest

from conftest import load_marketplace, repo_root

AGENT_PLUGINS_SCHEMA = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"

# The Agent Plugins 1.0.0 name grammar, transcribed from the published schema:
# 1-64 chars, lowercase alphanumeric plus '.' and '-', no leading or trailing
# separator, and no doubled separator.
AGENT_PLUGINS_NAME = re.compile(r"^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")

# `additionalProperties: false` in the published schema — an unrecognised key
# makes the manifest invalid rather than merely being ignored.
AGENT_PLUGINS_KEYS = {
    "$schema", "name", "version", "description", "author",
    "homepage", "repository", "license", "keywords", "extensions",
}

SEMVER = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")

# Every file that states a version, and how to reach it.
VERSIONED = {
    "plugin.json": lambda d: d["version"],
    "gemini-extension.json": lambda d: d["version"],
    ".codex-plugin/plugin.json": lambda d: d["version"],
    ".claude-plugin/plugin.json": lambda d: d["version"],
    ".claude-plugin/marketplace.json": lambda d: d["metadata"]["version"],
}

MANIFESTS = [
    "plugin.json",
    "gemini-extension.json",
    ".codex-plugin/plugin.json",
    ".claude-plugin/plugin.json",
    ".claude-plugin/marketplace.json",
]


def _load(rel: str) -> dict:
    return json.loads((repo_root() / rel).read_text(encoding="utf-8"))


@pytest.mark.parametrize("rel", MANIFESTS)
def test_manifest_exists_and_parses(rel):
    path = repo_root() / rel
    assert path.is_file(), f"{rel} is missing; an ecosystem loses one-command install"
    _load(rel)


@pytest.mark.parametrize("rel", MANIFESTS)
def test_manifest_is_not_empty(rel):
    assert _load(rel), f"{rel} parses but is empty"


# ---------------------------------------------------------------------------
# Agent Plugins v1 — the highest-leverage file, and the strictest schema
# ---------------------------------------------------------------------------

def test_agent_plugins_manifest_declares_the_schema():
    data = _load("plugin.json")
    assert data.get("$schema") == AGENT_PLUGINS_SCHEMA, (
        f"plugin.json must declare $schema {AGENT_PLUGINS_SCHEMA!r}; it is required "
        f"and pins the spec version clients validate against"
    )


def test_agent_plugins_name_matches_the_published_grammar():
    name = _load("plugin.json").get("name", "")
    assert AGENT_PLUGINS_NAME.match(name), (
        f"plugin.json name {name!r} violates the Agent Plugins grammar "
        f"(1-64 lowercase alphanumeric, '.' and '-', no leading/trailing/doubled separator)"
    )
    assert 1 <= len(name) <= 64, f"plugin.json name is {len(name)} chars, outside 1..64"


def test_agent_plugins_manifest_has_no_unrecognised_keys():
    """The schema sets `additionalProperties: false` — extra keys invalidate it."""
    extra = set(_load("plugin.json")) - AGENT_PLUGINS_KEYS
    assert not extra, (
        f"plugin.json has key(s) {sorted(extra)} outside the Agent Plugins schema, which "
        f"sets additionalProperties: false — the manifest is invalid, not merely verbose"
    )


def test_agent_plugins_manifest_declares_no_component_paths():
    """Component locations are fixed by the spec and cannot be overridden."""
    forbidden = {"skills", "mcp", "agents", "commands"} & set(_load("plugin.json"))
    assert not forbidden, (
        f"plugin.json declares {sorted(forbidden)}; Agent Plugins fixes component "
        f"locations (skills/, mcp.json) and forbids overriding them in the manifest"
    )


# ---------------------------------------------------------------------------
# Codex and Gemini
# ---------------------------------------------------------------------------

def test_codex_manifest_points_at_the_shared_skills_directory():
    declared = _load(".codex-plugin/plugin.json").get("skills")
    assert declared is not None, ".codex-plugin/plugin.json must declare a skills path"
    resolved = (repo_root() / declared.lstrip("./")).resolve()
    assert resolved == (repo_root() / "skills").resolve(), (
        f"Codex skills path {declared!r} resolves to {resolved}, not the shared skills/ "
        f"directory every other manifest uses"
    )


def test_gemini_extension_name_is_lowercase_dashed():
    name = _load("gemini-extension.json").get("name", "")
    assert re.match(r"^[a-z0-9]+(?:-[a-z0-9]+)*$", name), (
        f"gemini-extension.json name {name!r} must be lowercase with dashes, "
        f"not underscores or spaces"
    )


# ---------------------------------------------------------------------------
# Drift
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("rel", sorted(VERSIONED))
def test_declared_version_is_semver(rel):
    version = VERSIONED[rel](_load(rel))
    assert SEMVER.match(version), f"{rel}: version {version!r} is not semver"


def test_every_manifest_declares_the_same_version():
    """Five files state a version; a release that updates four ships a broken set."""
    versions = {rel: VERSIONED[rel](_load(rel)) for rel in VERSIONED}
    assert len(set(versions.values())) == 1, (
        f"manifest versions have drifted: {versions}"
    )


def test_marketplace_carries_the_metadata_copilot_reads():
    """Copilot CLI reads this same file and expects a `metadata` block.

    Without it Claude Code is unaffected, so the omission would be invisible
    until a Copilot user tried to add the marketplace.
    """
    data = load_marketplace()
    assert "metadata" in data, (
        ".claude-plugin/marketplace.json needs a 'metadata' block: Copilot CLI reads "
        "this file too and expects one, and its absence fails silently for Claude"
    )
    for field in ("description", "version"):
        assert field in data["metadata"], f"marketplace metadata is missing {field!r}"


def test_every_marketplace_plugin_entry_declares_a_version():
    missing = [e["name"] for e in load_marketplace()["plugins"] if "version" not in e]
    assert not missing, f"marketplace plugin entries without a version: {missing}"
