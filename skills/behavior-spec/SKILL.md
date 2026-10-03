---
name: behavior-spec
description: Use after a value-gate go, or when new behaviour with human-approved value needs defining before tests or code. Writes Given/When/Then scenarios as the acceptance criteria, confirms them through interactive prompts, and hands them to test-driven-development.
---

# Behaviour Specification

Stage 2 of the new-behaviour pipeline:

```text
value-gate  ->  behavior-spec  ->  test-driven-development
(is it worth it?)  (what should it do?)  (prove it, then build it)
```

**Core principle:** Describe what the system does for its beneficiary, in
terms they could verify, before deciding how to build it.

## When to Use

Use this skill when new or changed observable behaviour has a recorded go
from **value-gate**, or a human-approved goal on an assigned work item.

Do not start without one. If the value has not been agreed, load
**value-gate** first. Bug fixes, refactors, chores, and documentation-only
changes do not need scenarios; a bug fix needs a regression test instead.

## 1. Draft scenarios

Write one scenario per behaviour, from the beneficiary's point of view:

```markdown
### Scenario: <behaviour in plain words>
- **Given** <starting state>
- **When** <one action or event>
- **Then** <observable outcome>
```

Rules:

- One `When` per scenario. A second action is a second scenario.
- `Then` states something observable from outside: output, stored state, a
  message, a status. Never an internal call or a class name.
- Use the repository's domain terms. Name no implementation detail.
- Cover the main path first, then the failures and boundaries that the value
  statement makes important.
- Every scenario traces to the value statement. Drop any that does not.

If the repository already has a scenario format or `.feature` files, follow
that format instead. Do not add a BDD framework or any other dependency.

## 2. Confirm with the human

Scenarios are product decisions. Confirm them with interactive prompts:

- Use the assistant's interactive question tool when one is available. If
  none is, ask the same question as a numbered list in the conversation.
- Present the drafted scenarios, then ask about each open point: a missing
  path, an ambiguous outcome, a boundary whose expected result is unclear.
- Offer two to four suggested answers per question, with your recommendation
  first and labelled as recommended.
- Always allow a free-text answer, so the human can add a scenario or outcome
  of their own when no suggestion fits.
- Finish by asking whether the set is complete, with the options to approve,
  add a scenario, or change one.

## 3. Record and hand over

Record the approved scenarios as the acceptance criteria:

- a `## Scenarios` section in the structured task file when
  **task-workflow** task files are in use, with each scenario also listed as
  a checkbox under `## Acceptance Criteria`;
- otherwise the existing work item, or the conversation.

Approved scenarios are read-only. A change to one goes back to the human.

Then ask, as an interactive prompt, what happens next:

- **Start now**: load **test-driven-development**.
- **Record as a backlog item**: create the item and stop.
- **Both**: create the item, claim it, then load
  **test-driven-development**.

Create the item through **backlog-management**, with the value statement as
its goal and the approved scenarios as its acceptance criteria. If a backend
is already resolved, use it without asking again. If none is,
**backlog-management** asks which to use; never pick or create one silently.
Skip this question when the work already has a work item, and update that
item instead.

Approved scenarios make TDD the default: each scenario becomes a failing
acceptance test before any production code is written.

## Autonomous mode

An agent running without a human in the loop does not approve its own
scenarios.

- If the assigned item already has testable acceptance criteria, restate them
  as scenarios without changing their scope and continue to
  **test-driven-development**.
- If the criteria are missing or not testable, draft scenarios, report them
  as a blocker, and stop.
