---
name: architecture-planning
description: Use when making architectural decisions, designing systems or components, choosing technologies, defining boundaries, or evaluating structural trade-offs. Maintains a living architecture.md and records decisions as ADRs. Language- and stack-agnostic.
---

# Architecture Planning

## When This Applies

Engage this skill when a change touches **structure**, not just implementation:

- Introducing or removing a service, module, layer, or boundary
- Choosing a technology, framework, datastore, protocol, or external dependency
- Defining how components communicate (sync/async, API style, events, contracts)
- Data modelling, ownership, and consistency decisions
- Cross-cutting concerns: auth, observability, error handling, config, security, scaling
- Anything expensive to reverse later

If a task surfaces one of these, **stop and plan here before coding** — this is the "Surface blockers" path from **task-workflow** skill.

## Legacy Layout Migration

Older projects may still have `<root>/.agents/architecture.md`. Before reading or editing the architecture doc, check once per project:

1. If `<root>/.agents/architecture.md` exists and `<root>/.planning/architecture.md` does not, create `<root>/.planning/` (if missing) and move the file there.
2. Do this silently and automatically — it is additive and safe. Do not ask for confirmation.

## Two Artifacts

| Artifact | Location | Purpose |
|---|---|---|
| `architecture.md` | in `<root>/.planning/` | Living description of the system **as it is now** |
| ADR entries | `## Decisions` log in `architecture.md` | Immutable record of **why** a decision was made, with context and alternatives |

Rule of thumb: `architecture.md` answers *"how does this work today?"*; ADRs answer *"why is it this way?"*. Keep `architecture.md` current by editing it; never rewrite history in an ADR — supersede it instead.

## architecture.md Structure

Keep it short and current. Delete stale sections rather than letting them rot.

```markdown
# Architecture

**Last updated:** <date>

## 1. Overview
One paragraph: what the system does and its core design philosophy.

## 2. Context & Constraints
- Business/technical drivers shaping the design
- Hard constraints (compliance, latency, budget, team size, existing systems)
- Explicit non-goals — what this system intentionally does NOT do

## 3. System Structure
- Components/services/modules and their responsibilities
- A diagram (Mermaid/ASCII) of how they connect
- Boundaries: what each owns, what it must not reach into

## 4. Data
- Key entities and ownership (who is the source of truth)
- Storage choices and why
- Consistency / migration approach

## 5. Cross-Cutting Concerns
Auth, observability, error handling, config, security, scaling — one line each, link out for detail.

## 6. Key Decisions
Index of ADRs with status. Link each.

## 7. Known Trade-offs & Risks
What was knowingly accepted, and what would force a rethink.
```

## ADR Structure

One decision per record. Numbered, dated, never deleted.

```markdown
# ADR-<NNNN>: <short title>

**Status:** proposed | accepted | superseded by ADR-<N> | deprecated
**Date:** <date>

## Context
The forces at play: problem, constraints, what made this a decision worth recording.

## Decision
What we chose, stated plainly.

## Alternatives Considered
Each real option, with why it was rejected. "No alternatives" usually means the analysis is missing.

## Consequences
What becomes easier, what becomes harder, what we now owe (follow-ups, risks, migration cost).
```

## Decision Process

Work through these as a dialogue with the user — do not decide unilaterally on structural matters.

1. **Frame the problem.** State what is actually being decided and why now. Separate the decision from the implementation.
2. **Surface constraints & drivers.** Quality attributes first (performance, security, scalability, maintainability, cost, team capability). Name the ones that dominate — you cannot maximise all.
3. **Generate real alternatives.** At least two genuine options, including "do nothing / defer." Bias toward the simplest thing that satisfies the constraints (KISS, YAGNI).
4. **Evaluate against drivers, not preference.** Trade-offs explicitly: what each option costs. Prefer reversible decisions; spend the analysis budget on the irreversible ones.
5. **Recommend, then confirm.** Give a clear recommendation with reasoning — not an unranked survey. Get user agreement before recording.
6. **Record.** Write the ADR and update the affected `architecture.md` sections in the same change.

## Agent Discipline

- A structural decision is a **Blocker** in `/task-workflow` terms — surface it, do not guess.
- No new service, dependency, or boundary without an ADR and a recommendation the user has confirmed.
- When a change makes `architecture.md` wrong, update it in the same branch — treat it like a failing test.
- Superseding a decision: set the old ADR's status to `superseded by ADR-N`, write the new one; never edit the original's reasoning.
