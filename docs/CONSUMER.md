# Consuming this repo as a plugin

This repo publishes a Claude Code plugin marketplace (`aanyberg`) with one plugin, `conventions`. The repository root *is* the plugin, so its portable [`skills`](../skills) sit at the top level. Canonical [`agent-sources`](../agent-sources) are rendered only by the package installer so provider-specific metadata never leaks into another provider. Consumer repos load plugin skills directly — no copying or symlinking into `~/.claude`.

## `.claude/settings.json`

Add the marketplace and enable the plugin in the consumer repo's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "aanyberg": {
      "source": {
        "source": "github",
        "repo": "aanyberg/agent-conventions"
      }
    }
  },
  "enabledPlugins": {
    "conventions@aanyberg": true
  }
}
```

`aanyberg/agent-conventions` is public, so no additional credentials are needed to reach it.

> **Migrating from `lahnvik`:** the marketplace was renamed from `lahnvik` to `aanyberg`. GitHub redirects the old
> repository name, but marketplace keys are not redirected — change `conventions@lahnvik` to `conventions@aanyberg`
> in `enabledPlugins`, and rename the `extraKnownMarketplaces` key to match, or the plugin will stop resolving.

## Not using Claude Code?

The skills in this repo are portable — [`skills/`](../skills) follows the [Agent Skills specification](https://agentskills.io/specification), so Codex, GitHub Copilot, OpenCode, Cursor and Gemini CLI can all load the same copy. Agents have no equivalent cross-provider file specification; the package installer renders the canonical definitions into each provider's native format and path. The rest of this document covers the Claude Code plugin route specifically; for other providers see **Agents — every target provider** in the root [README.md](../README.md).

## Repository-native behavior

Installing or enabling the plugin does not impose its planning workflow.
Skills follow the consumer repository's existing instructions and
conventions. They create no policy, backlog, task hierarchy, architecture
record, branch, or changelog solely because the plugin is present.

This is the right mode for repositories that already have their own tracker
and contribution process, and for new repositories that only want the
language, testing, review, and documentation guidance.

## Choosing backlog tracking

The backlog skill does not use a central configuration file. For a backlog
operation it checks, in order:

1. The backend explicitly named in the request.
2. Repository instructions naming a tracker.
3. An established `BACKLOG.md` or GitHub Issues work-item structure, including
   repository-specific labels, fields, projects, or statuses.

If those signals do not identify one backend, the agent asks whether to use
GitHub Issues, `BACKLOG.md`, or no persistent backlog. A GitHub remote by itself
does not select GitHub Issues. To make a choice permanent, document it in the
repository's existing `AGENTS.md` or contributing guide.

Structured task files and ADRs are independent. The corresponding skills follow
established repository requirements, including required ADRs. They establish a
new task or ADR convention only after an explicit request and confirmation.

## Local setup (one-time, per machine)

```bash
claude plugin marketplace add aanyberg/agent-conventions
claude plugin install conventions@aanyberg
```

If the consumer repo already commits the `.claude/settings.json` above, `claude plugin marketplace add` runs automatically when the repo is trusted, and `claude plugin install` is the only manual step.

## Fallback

If a session's environment can't reach `aanyberg/agent-conventions` on GitHub (e.g. a cloud sandbox without private-repo proxy access), the marketplace won't load. There is currently no sync script in this repo for that case — see the note in the root [README.md](../README.md) before scripting a workaround.
