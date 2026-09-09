"""Behavioural tests for the shell scripts the plugin ships.

These are the only executable logic in the repo. Each test runs the real
script in a throwaway git repo with a stubbed `gh`, so nothing depends on
the developer's own GitHub auth or network.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest
import yaml

from conftest import repo_root

SCRIPTS = repo_root() / "skills" / "backlog-management" / "scripts"
DETECT = SCRIPTS / "detect-backend.sh"
GENERATE = SCRIPTS / "generate-policy.sh"
TEMPLATE = repo_root() / "policy.example.yml"

# A `gh` stub driven by env vars, so every case is deterministic regardless of
# whether the machine running the suite has gh installed or authenticated.
GH_STUB = """\
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") [[ "${STUB_GH_AUTHED:-0}" == "1" ]] && exit 0 || exit 1 ;;
esac
if [[ "$1" == "api" ]]; then
  [[ "${STUB_GH_AUTHED:-0}" == "1" ]] || exit 1
  echo "${STUB_GH_HAS_ISSUES:-false}"
  exit 0
fi
exit 1
"""


@pytest.fixture
def sandbox(tmp_path: Path) -> Path:
    """An initialised git repo with no remote."""
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=tmp_path, check=True)
    return tmp_path


@pytest.fixture
def stub_bin(tmp_path: Path) -> Path:
    """A bin directory shadowing `gh` with the controllable stub."""
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    gh = bin_dir / "gh"
    gh.write_text(GH_STUB)
    gh.chmod(0o755)
    return bin_dir


def run(script: Path, cwd: Path, stub_bin: Path, **stub_env: str):
    env = dict(os.environ)
    env["PATH"] = f"{stub_bin}{os.pathsep}{env['PATH']}"
    env.update(stub_env)
    return subprocess.run(
        ["bash", str(script)], cwd=cwd, env=env, capture_output=True, text=True
    )


def write_policy(root: Path, backend_line: str) -> None:
    (root / ".planning").mkdir(exist_ok=True)
    (root / ".planning" / "policy.yml").write_text(
        textwrap.dedent(f"""\
        backlog:
          {backend_line}
          render_file: BACKLOG.md
        """)
    )


def add_github_remote(root: Path) -> None:
    subprocess.run(
        ["git", "remote", "add", "origin", "https://github.com/example/repo.git"],
        cwd=root, check=True,
    )


# --------------------------------------------------------------------------
# detect-backend.sh
# --------------------------------------------------------------------------

def test_detect_reports_none_in_an_empty_repo(sandbox, stub_bin):
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout.strip() == "none"
    assert result.returncode == 1, "callers branch on the exit code, not just the output"


def test_detect_falls_back_to_markdown_when_a_backlog_file_exists(sandbox, stub_bin):
    (sandbox / "BACKLOG.md").write_text("# Backlog\n")
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout.strip() == "markdown"
    assert result.returncode == 0


@pytest.mark.parametrize(
    "backend_line, expected",
    [
        ("backend: markdown", "markdown"),
        ("backend: github-issues", "github-issues"),
        ("backend: markdown # pinned by hand", "markdown"),
        ("backend:   markdown", "markdown"),
    ],
)
def test_detect_honours_an_explicit_backend(sandbox, stub_bin, backend_line, expected):
    write_policy(sandbox, backend_line)
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout.strip() == expected
    assert result.stdout.strip() == result.stdout.strip().strip(), (
        f"output {result.stdout!r} carries stray whitespace; callers compare it literally"
    )


def test_detect_output_has_no_surrounding_whitespace(sandbox, stub_bin):
    """Callers do `[[ "$(detect-backend.sh)" == markdown ]]` — padding breaks that."""
    write_policy(sandbox, "backend: markdown")
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout == "markdown\n", f"expected exactly 'markdown\\n', got {result.stdout!r}"


def test_detect_prefers_auto_detection_over_backend_auto(sandbox, stub_bin):
    write_policy(sandbox, "backend: auto")
    (sandbox / "BACKLOG.md").write_text("# Backlog\n")
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout.strip() == "markdown"


def test_detect_uses_github_when_auto_and_issues_are_enabled(sandbox, stub_bin):
    write_policy(sandbox, "backend: auto")
    add_github_remote(sandbox)
    result = run(DETECT, sandbox, stub_bin, STUB_GH_AUTHED="1", STUB_GH_HAS_ISSUES="true")
    assert result.stdout.strip() == "github-issues"


def test_detect_ignores_github_when_gh_is_not_authenticated(sandbox, stub_bin):
    write_policy(sandbox, "backend: auto")
    add_github_remote(sandbox)
    (sandbox / "BACKLOG.md").write_text("# Backlog\n")
    result = run(DETECT, sandbox, stub_bin, STUB_GH_AUTHED="0")
    assert result.stdout.strip() == "markdown"


def test_detect_ignores_github_when_issues_are_disabled(sandbox, stub_bin):
    write_policy(sandbox, "backend: auto")
    add_github_remote(sandbox)
    (sandbox / "BACKLOG.md").write_text("# Backlog\n")
    result = run(DETECT, sandbox, stub_bin, STUB_GH_AUTHED="1", STUB_GH_HAS_ISSUES="false")
    assert result.stdout.strip() == "markdown"


def test_detect_guards_against_an_incomplete_github_migration(sandbox, stub_bin):
    """policy says github-issues, but BACKLOG.md still holds live rows."""
    write_policy(sandbox, "backend: github-issues")
    (sandbox / "BACKLOG.md").write_text("| 001 | do a thing | ready |\n")
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout.strip() == "markdown"
    assert "migration incomplete" in result.stderr, "the reason must reach stderr"
    assert result.returncode == 0


def test_detect_trusts_github_once_migration_is_recorded(sandbox, stub_bin):
    write_policy(sandbox, "backend: github-issues")
    (sandbox / "BACKLOG.md").write_text("| 001 | do a thing | ready |\n")
    (sandbox / ".planning" / "backlog-migration.json").write_text("{}")
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout.strip() == "github-issues"


def test_detect_ignores_a_rendered_backlog_with_no_live_rows(sandbox, stub_bin):
    write_policy(sandbox, "backend: github-issues")
    (sandbox / "BACKLOG.md").write_text("# Backlog\n\nRendered from GitHub Issues.\n")
    result = run(DETECT, sandbox, stub_bin)
    assert result.stdout.strip() == "github-issues"


# --------------------------------------------------------------------------
# generate-policy.sh
# --------------------------------------------------------------------------

def test_generate_creates_a_policy_file(sandbox, stub_bin):
    result = run(GENERATE, sandbox, stub_bin)
    assert result.returncode == 0, result.stderr
    generated = sandbox / ".planning" / "policy.yml"
    assert generated.is_file()
    assert isinstance(yaml.safe_load(generated.read_text()), dict)


def test_generate_differs_from_the_template_only_in_the_backend_line(sandbox, stub_bin):
    run(GENERATE, sandbox, stub_bin)
    generated = (sandbox / ".planning" / "policy.yml").read_text().splitlines()
    template = TEMPLATE.read_text().splitlines()
    assert len(generated) == len(template), "generation must not add or drop lines"
    differences = [(t, g) for t, g in zip(template, generated) if t != g]
    assert differences == [("  backend: auto", "  backend: markdown")], differences


def test_generate_is_idempotent(sandbox, stub_bin):
    run(GENERATE, sandbox, stub_bin)
    generated = sandbox / ".planning" / "policy.yml"
    generated.write_text(generated.read_text().replace("markdown", "github-issues"))
    edited = generated.read_text()

    second = run(GENERATE, sandbox, stub_bin)
    assert second.returncode == 0
    assert generated.read_text() == edited, "a second run must never overwrite local edits"
    assert "already exists" in second.stdout


def test_generate_detects_github_issues(sandbox, stub_bin):
    add_github_remote(sandbox)
    result = run(GENERATE, sandbox, stub_bin, STUB_GH_AUTHED="1", STUB_GH_HAS_ISSUES="true")
    policy = yaml.safe_load((sandbox / ".planning" / "policy.yml").read_text())
    assert policy["backlog"]["backend"] == "github-issues"
    assert "github-issues" in result.stdout, "the report must state what it detected"


def test_generate_defaults_to_markdown_without_github(sandbox, stub_bin):
    result = run(GENERATE, sandbox, stub_bin)
    policy = yaml.safe_load((sandbox / ".planning" / "policy.yml").read_text())
    assert policy["backlog"]["backend"] == "markdown"
    assert "markdown" in result.stdout


def test_generate_fails_loudly_when_the_template_is_missing(sandbox, stub_bin, tmp_path):
    """The script resolves its template three levels up, so mirror that layout.

    Only the script and the template position are recreated — copying the whole
    plugin root would now mean copying the entire repository.
    """
    copied = tmp_path / "plugin-copy"
    scripts = copied / "skills" / "backlog-management" / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(GENERATE, scripts / GENERATE.name)
    assert not (copied / "policy.example.yml").exists(), "template must be absent for this case"

    result = run(scripts / "generate-policy.sh", sandbox, stub_bin)
    assert result.returncode == 1
    assert "Template not found" in result.stderr
    assert not (sandbox / ".planning" / "policy.yml").exists(), "must not leave a partial file"


# --------------------------------------------------------------------------
# The two scripts together
# --------------------------------------------------------------------------

@pytest.mark.parametrize(
    "authed, has_issues, expected",
    [("0", "false", "markdown"), ("1", "true", "github-issues")],
)
def test_generated_policy_is_read_back_identically(sandbox, stub_bin, authed, has_issues, expected):
    """What generate-policy.sh writes, detect-backend.sh must read back unchanged."""
    add_github_remote(sandbox)
    run(GENERATE, sandbox, stub_bin, STUB_GH_AUTHED=authed, STUB_GH_HAS_ISSUES=has_issues)
    result = run(DETECT, sandbox, stub_bin, STUB_GH_AUTHED=authed, STUB_GH_HAS_ISSUES=has_issues)
    assert result.stdout == f"{expected}\n", (
        f"generate-policy.sh wrote {expected!r} but detect-backend.sh returned "
        f"{result.stdout!r}"
    )


# --------------------------------------------------------------------------
# Static analysis
# --------------------------------------------------------------------------

def test_shellcheck_is_available():
    """shellcheck-py vendors the binary; a missing one would silently skip the lint."""
    assert shutil.which("shellcheck"), "shellcheck not on PATH — is the dev group installed?"


@pytest.mark.parametrize(
    "script", sorted(repo_root().glob("skills/*/scripts/*.sh")),
    ids=lambda p: str(p.relative_to(repo_root())),
)
def test_shellcheck_is_clean(script):
    result = subprocess.run(
        ["shellcheck", "--severity=warning", "--shell=bash", str(script)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"\n{result.stdout}{result.stderr}"


# --------------------------------------------------------------------------
# Portability
# --------------------------------------------------------------------------
#
# These scripts run on contributors' machines, where `sed` and `grep` are BSD
# rather than GNU. shellcheck does not parse regex arguments, so it reports
# nothing here — this check exists because a `\s` in `sed -E` silently produced
# a wrong backend on macOS while passing every Linux run.

# GNU/PCRE escapes with no POSIX equivalent. BSD tools read `\s` as a literal
# 's' rather than erroring, so the failure is silent and data-dependent.
GNU_ONLY_ESCAPES = {
    r"\s": "[[:space:]]", r"\S": "[^[:space:]]",
    r"\d": "[[:digit:]]", r"\D": "[^[:digit:]]",
    r"\w": "[[:alnum:]_]", r"\W": "[^[:alnum:]_]",
    r"\b": "an explicit delimiter", r"\B": "an explicit delimiter",
}

# Flags that exist on GNU but not BSD, or mean something different there.
GNU_ONLY_FLAGS = {
    "grep -P": "BSD grep has no PCRE mode; use -E with POSIX classes",
    "sed -i ": "BSD sed requires a backup suffix; use `sed -i ''` or a temp file",
    "readlink -f": "BSD readlink has no -f; use a cd/pwd subshell",
    "date -d": "BSD date has no -d; use -j -f",
}


def _regex_lines(script: Path) -> list[tuple[int, str]]:
    return [
        (n, line)
        for n, line in enumerate(script.read_text(encoding="utf-8").splitlines(), 1)
        if ("sed" in line or "grep" in line) and not line.lstrip().startswith("#")
    ]


@pytest.mark.parametrize(
    "script", sorted(repo_root().glob("skills/*/scripts/*.sh")),
    ids=lambda p: str(p.relative_to(repo_root())),
)
def test_no_gnu_only_regex_escapes(script):
    findings = [
        f"line {n}: {escape!r} is GNU-only — use {replacement} ({line.strip()})"
        for n, line in _regex_lines(script)
        for escape, replacement in GNU_ONLY_ESCAPES.items()
        if escape in line
    ]
    assert not findings, (
        f"{script.relative_to(repo_root())} would behave differently under BSD "
        f"sed/grep:\n  " + "\n  ".join(findings)
    )


@pytest.mark.parametrize(
    "script", sorted(repo_root().glob("skills/*/scripts/*.sh")),
    ids=lambda p: str(p.relative_to(repo_root())),
)
def test_no_gnu_only_flags(script):
    text = script.read_text(encoding="utf-8")
    findings = [f"{flag!r}: {why}" for flag, why in GNU_ONLY_FLAGS.items() if flag in text]
    assert not findings, f"{script.relative_to(repo_root())}:\n  " + "\n  ".join(findings)
