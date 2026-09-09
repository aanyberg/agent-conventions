"""The policy template is a contract: skills read keys from the file it generates."""

from __future__ import annotations

import re

import pytest
import yaml

from conftest import agent_files, repo_root, skill_files

TEMPLATE = repo_root() / "policy.example.yml"

# Policy keys as written in skill and agent prose, in both forms used:
# `policy.git.branch_format` and the bare `git.branch_format`.
TOP_LEVEL = "backlog|ids|statuses|states|git|review|versioning|autonomous|checks|worktrees|tests|reporting"
POLICY_REF = re.compile(rf"\b(?:policy\.)?((?:{TOP_LEVEL})(?:\.[a-z_]+)+)\b")

# `backlog.md` and friends are filenames, not policy keys.
FILE_EXTENSIONS = {"md", "yml", "yaml", "json", "sh", "py", "toml"}


def _flatten(node, prefix: str = "") -> set[str]:
    keys: set[str] = set()
    if isinstance(node, dict):
        for key, value in node.items():
            path = f"{prefix}{key}"
            keys.add(path)
            keys |= _flatten(value, f"{path}.")
    return keys


def _template() -> dict:
    return yaml.safe_load(TEMPLATE.read_text(encoding="utf-8"))


def _referenced_keys() -> dict[str, list[str]]:
    refs: dict[str, list[str]] = {}
    for path in skill_files() + agent_files():
        text = path.read_text(encoding="utf-8")
        for key in POLICY_REF.findall(text):
            if key.rsplit(".", 1)[-1] in FILE_EXTENSIONS:
                continue
            refs.setdefault(key, []).append(str(path.relative_to(repo_root())))
    return refs


def test_template_exists():
    assert TEMPLATE.is_file(), f"policy template missing at {TEMPLATE}"


def test_template_is_valid_yaml():
    assert isinstance(_template(), dict), "policy template must parse to a mapping"


def test_backend_is_auto_so_generate_policy_can_substitute_it():
    """generate-policy.sh rewrites the literal `backend: auto` line."""
    text = TEMPLATE.read_text(encoding="utf-8")
    assert re.search(r"^\s*backend: auto\s*$", text, re.MULTILINE), (
        "template has no `backend: auto` line; generate-policy.sh's sed "
        "substitution would silently do nothing"
    )


def test_there_is_exactly_one_policy_template():
    """A second copy drifts from the one generate-policy.sh actually ships."""
    copies = sorted(
        str(p.relative_to(repo_root()))
        for p in repo_root().rglob("policy.example.yml")
        if ".git" not in p.parts
    )
    assert copies == ["policy.example.yml"], (
        f"expected a single policy template, found {copies}"
    )


@pytest.mark.parametrize("key", sorted(_referenced_keys()))
def test_referenced_policy_key_exists_in_template(key):
    available = _flatten(_template())
    assert key in available, (
        f"skills reference policy.{key} but the generated policy.yml has no such key "
        f"(referenced in: {', '.join(sorted(set(_referenced_keys()[key])))})"
    )
