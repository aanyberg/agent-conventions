---
name: value-gate
description: Use when a new feature, capability, or behaviour change is proposed, before any specification, test, or code is written. Asks whether the change adds value, gets a human go/no-go through interactive prompts, and hands a go to behavior-spec.
---

# Value Gate

Stage 1 of the new-behaviour pipeline:

```text
value-gate  ->  behavior-spec  ->  test-driven-development
(is it worth it?)  (what should it do?)  (prove it, then build it)
```

**Core principle:** Nothing is specified, tested, or built until a human has
agreed that it is worth having.

## When to Use

Use this skill when a proposal adds or changes behaviour a user, operator, or
calling system can observe.

Skip the gate, and say that you skipped it, for:

- bug fixes that restore already-agreed behaviour;
- refactors, dependency or tooling chores, and documentation-only changes;
- work whose value a human has already approved, such as an assigned work item
  with a stated goal. Go straight to **behavior-spec**.

## 1. Draft the value statement

Inspect the repository before asking anything. Then draft:

| Field | Content |
|---|---|
| Beneficiary | Who gains: user role, operator, or calling system |
| Problem | What they cannot do, or do badly, today |
| Observable change | What will be different once this exists |
| Existing coverage | Behaviour, configuration, or tooling that already solves part or all of it |
| Cost of not doing it | What happens if the proposal is dropped |

Fill each field from evidence in the repository and the conversation. Mark a
field `unknown` rather than inventing an answer.

## 2. Ask the human

The verdict belongs to a human. Resolve each open point with an interactive
prompt:

- Use the assistant's interactive question tool when one is available. If
  none is, ask the same question as a numbered list in the conversation.
- Ask one question per open point, starting with any field marked `unknown`.
- Offer two to four concrete suggested answers drawn from the repository and
  the proposal, with your recommendation first and labelled as recommended.
- Always allow a free-text answer, so the human can supply their own when no
  suggestion fits.
- Do not ask about anything the repository or conversation already answers.

End with the verdict question, with these suggested answers:

- **Go**: the value is clear; continue to **behavior-spec**.
- **Go, narrowed**: only part of the proposal earns its place; record which.
- **No-go**: existing behaviour covers it, or the value does not justify it.
- **Explore**: the value is not yet known; find out before deciding.
- **Park**: worthwhile, but not now.

Give your own recommendation and the reason for it. Recommend no-go when the
"Existing coverage" field already solves the problem. Recommend explore or
no-go, never go, while "Beneficiary" or "Problem" is still `unknown` after
asking. A go is not approved on a guess.

## 3. Explore when the value is unknown

The human does not need to arrive knowing the value. When they cannot tell,
or choose explore:

1. State the one question that would settle the value.
2. Propose the cheapest way to answer it, as an interactive prompt with
   suggested options and a free-text answer. Typical options: check existing
   data, logs, or usage; ask the affected users; build a disposable spike.
3. Agree a fixed scope for the exploration, then carry it out.
4. Return to step 2 of this skill with the evidence and ask for the verdict
   again.

A spike is throwaway code that answers the question and nothing more. It is
exempt from **behavior-spec** and **test-driven-development**, stays on its
own branch, and is never merged. If the verdict becomes go, build the feature
again through the pipeline.

## 4. Record the verdict

Record the value statement and verdict where the work is tracked:

- a `## Value` section in the structured task file when **task-workflow**
  task files are in use;
- otherwise the existing work item, or the conversation.

Do not create a task file, backlog, or document just to hold the verdict.

| Verdict | Next step |
|---|---|
| Go / Go, narrowed | Load **behavior-spec** with the recorded value statement |
| Explore | Run the agreed exploration, then ask for the verdict again |
| No-go | Stop. Write no specification, tests, or code |
| Park | Stop. Record it through **backlog-management** only if a backend is already selected or the human asks |

## Autonomous mode

An agent running without a human in the loop never approves its own value
gate.

- If the assigned item already carries a human-approved goal, treat that as
  the go and continue to **behavior-spec**.
- Otherwise draft the value statement, report it as a blocker with your
  recommendation, and stop. Do not start an exploration unprompted.
