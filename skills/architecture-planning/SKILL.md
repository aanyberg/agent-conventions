---
name: architecture-planning
description: Use when making architectural decisions, designing systems or components, choosing technologies, defining boundaries, or evaluating structural trade-offs. Follows existing decision-record practices and can propose ADRs when none exist.
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

If a task surfaces one of these, stop and resolve the decision before coding.
When a structured task workflow is in use, record the unresolved choice as a
blocker there.

## Decision records

Before writing an architecture artifact:

1. Inspect repository instructions and existing architecture or ADR files.
2. Follow the established location, naming, and status conventions.
3. If no convention exists, complete the analysis in the conversation.
4. Create or update a persistent architecture record when repository practice
   requires it or the user explicitly asks for one. Propose and confirm a
   location only when establishing a new convention.

Do not create `.planning/`, migrate legacy files, or establish an ADR system
merely because this skill was loaded.

## Optional artifacts

When the repository uses them:

- A living architecture document answers "how does this work today?"
- ADRs answer "why is it this way?"

Keep the living document current. Never rewrite accepted ADR history; supersede
an old decision with a new record.

## Suggested architecture document structure

Use this only when creating a new architecture document at the user's request
and the repository has no template:

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

## Suggested ADR structure

Use this only when the repository has no ADR template. Keep one decision per
record, number and date it, and never delete accepted history.

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
6. **Record when requested or established.** Use the repository's existing
   decision-record practice whenever it requires a record. If none exists,
   return the confirmed decision in the response unless the user asked to
   create a persistent record.

## Agent Discipline

- Surface structural decisions; do not guess. Record unresolved choices in the
  active task system when one exists.
- Require an ADR only when the repository already requires ADRs or the user
  explicitly requests a new decision record.
- Update an existing architecture document when the change makes it wrong.
- Supersede existing ADRs according to the repository's convention; never
  rewrite accepted reasoning.
