---
name: test-driven-development
description: Use when implementing any feature or bugfix, before writing implementation code
---

# Test-Driven Development (TDD)

## Overview

Write the test first. Watch it fail. Write minimal code to pass.

**Core principle:** If you didn't watch the test fail, you don't know if it tests the right thing.

**Scope:** TDD is the *loop* for building one behavior at a time. To decide *which* behaviors deserve tests and *what* coverage to aim for, work out the plan with the **testing-strategy** skill first, then drive each item through the cycle below.

## When to Use

**Always:** new features, bug fixes, refactoring, behavior changes.

**Exceptions (confirm with user):** throwaway prototypes, generated code, configuration files.

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

Write code before the test? Delete it. No exceptions — no keeping it as "reference," no "adapting" it. Delete means delete.

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

## Red Flags — Stop and Start Over

- Code written before test
- Test added after implementation
- Test passes immediately without explanation
- Can't explain why the test failed
- Rationalizing "just this once"
- "I already manually tested it"
- "Tests after achieve the same purpose"
- "Keep as reference" or "adapt existing code"
- "Already spent X hours, deleting is wasteful"
- "TDD is dogmatic, I'm being pragmatic"
- "This is different because..."
- "It's about spirit not ritual"

**All of these mean: delete the code, start over with TDD.**

## Verification Checklist

Before marking work complete:

- [ ] Every new function/method has a test
- [ ] Watched each test fail before implementing
- [ ] Each test failed for expected reason (feature missing, not typo)
- [ ] Wrote minimal code to pass each test
- [ ] All tests pass
- [ ] Output pristine (no errors, warnings)
- [ ] Tests use real code (mocks only if unavoidable)
- [ ] Edge cases and errors covered

Can't check all boxes? You skipped TDD. Start over.
