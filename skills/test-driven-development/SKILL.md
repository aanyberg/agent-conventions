---
name: test-driven-development
description: Use when implementing behaviour that has approved scenarios from behavior-spec, when the user requests test-driven development, or when the repository already follows a red-green-refactor workflow.
---

# Test-Driven Development (TDD)

## Overview

Write the test first. Watch it fail. Write minimal code to pass.

**Core principle:** If you didn't watch the test fail, you don't know if it tests the right thing.

**Scope:** TDD is the *loop* for building one behavior at a time. To decide *which* behaviors deserve tests and *what* coverage to aim for, work out the plan with the **testing-strategy** skill first, then drive each item through the cycle below.

## When to Use

TDD is the default for new behaviour. It is stage 3 of the pipeline
**value-gate** -> **behavior-spec** -> **test-driven-development**: once
scenarios are approved, implement them through the loop below.

Also use TDD when the user requests it, the repository documents it, or an
existing task explicitly requires a red-green-refactor loop. Otherwise follow
the repository's normal testing workflow and still add appropriate regression
coverage for changed behavior.

New behaviour with no approved scenarios is not ready for TDD. Load
**behavior-spec** first, or **value-gate** if its value has not been agreed.

Typical exceptions even in a TDD project are generated code, configuration-only
changes, and disposable prototypes.

## The TDD constraint

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

While using TDD, do not write production behavior before its failing test.

## From scenarios to tests

When approved scenarios exist, work through them one at a time:

1. Turn the scenario into one acceptance test at the outermost boundary the
   repository's tests can reach. `Given` is the setup, `When` the action,
   `Then` the assertions. Name the test after the scenario.
2. Watch it fail because the behaviour is missing.
3. Drive the implementation with the Red-Green-Refactor loop below, adding
   smaller tests as the design needs them, until the acceptance test passes.
4. Move to the next scenario.

Do not change a scenario to make a test pass. If one proves wrong or
incomplete, take it back to the human through **behavior-spec**.

## Red-Green-Refactor

### RED — Write Failing Test

Write one minimal test showing what should happen. Pick the behavior from your test plan — cover business-critical paths, error handling, edge cases, and security boundaries first; skip trivial getters/setters and framework code (see the **testing-strategy** skill).

**Requirements:**
- Tests one behavior
- Name describes the behavior
- Uses real code (no mocks unless unavoidable)

### Verify RED — Watch It Fail

**MANDATORY. Never skip.**

Run the test and confirm:
- It fails (not errors)
- Failure message is expected
- It fails because the feature is missing, not due to typos

Test passes immediately? You're testing existing behavior — fix the test.

### GREEN — Write Minimal Code

Write the simplest code that passes the test. Do not add features, refactor other code, or "improve" beyond what the test requires.

### Verify GREEN — Watch It Pass

**MANDATORY.**

Run the test suite and confirm:
- The new test passes
- All other tests still pass
- Output is clean (no errors or warnings)

Test fails? Fix code, not test. Other tests fail? Fix them now.

### REFACTOR — Clean Up

After green only: remove duplication, improve names, extract helpers. Keep tests green. Do not add behavior.

### Repeat

Write the next failing test for the next behavior.

## Good Tests

| Quality | Good | Bad |
|---------|------|-----|
| **Minimal** | One thing. "and" in name? Split it. | `test('validates email and domain and whitespace')` |
| **Clear** | Name describes the behavior | `test('test1')` |
| **Shows intent** | Demonstrates desired API | Obscures what code should do |

## Red flags while using TDD

- Code written before test
- Test added after implementation
- Test passes immediately without explanation
- Can't explain why the test failed
- Rationalizing "just this once"
- "I already manually tested it"
- "Tests after achieve the same purpose"
- "Keep as reference" or "adapt existing code"
- "Already spent X hours, deleting is wasteful"
- "This is different because..."
- "It's about spirit not ritual"

These indicate that the agreed TDD loop was skipped. Return to the missing red
step before continuing.

## Verification Checklist

Before marking work complete:

- [ ] Every approved scenario has a passing acceptance test
- [ ] Every new function/method has a test
- [ ] Watched each test fail before implementing
- [ ] Each test failed for expected reason (feature missing, not typo)
- [ ] Wrote minimal code to pass each test
- [ ] All tests pass
- [ ] Output pristine (no errors, warnings)
- [ ] Tests use real code (mocks only if unavoidable)
- [ ] Edge cases and errors covered

If a box cannot be checked, state why and follow the repository's agreed
testing process.
