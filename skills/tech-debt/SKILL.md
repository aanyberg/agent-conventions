---
name: tech-debt
description: Identify, categorize, and prioritize technical debt. Trigger with "tech debt", "technical debt audit", "what should we refactor", "code health", or when the user asks about code quality, refactoring priorities, or maintenance backlog.
---

# Tech Debt Management

Systematically identify, categorize, and prioritize technical debt.

## Categories

| Type | Examples | Risk |
|------|----------|------|
| **Code debt** | Duplicated logic, poor abstractions, magic numbers | Bugs, slow development |
| **Architecture debt** | Monolith that should be split, wrong data store | Scaling limits |
| **Test debt** | Low coverage, flaky tests, missing integration tests | Regressions ship |
| **Dependency debt** | Outdated libraries, unmaintained dependencies | Security vulns |
| **Documentation debt** | Missing runbooks, outdated READMEs, tribal knowledge | Onboarding pain |
| **Infrastructure debt** | Manual deploys, no monitoring, no IaC | Incidents, slow recovery |

## Prioritization Framework

Score each item on:
- **Impact**: How much does it slow the team down? (1 = negligible, 5 = severe)
- **Risk**: What happens if we don't fix it? (1 = harmless, 5 = critical)
- **Effort**: How hard is the fix? (1 = trivial, 5 = very hard)

Priority = (Impact + Risk) × (6 − Effort)

Score Effort on its raw scale — the `(6 − Effort)` term inverts it so cheap, high-value fixes rank highest. Higher score = higher priority.

**Example:** A flaky test suite (Impact 4, Risk 3, Effort 2) scores `(4 + 3) × (6 − 2) = 28`. A monolith split (Impact 5, Risk 4, Effort 5) scores `(5 + 4) × (6 − 5) = 9` — high value, but its cost pushes it below cheaper wins.

## Output

Produce a prioritized list with estimated effort, business justification for each item, and a phased remediation plan that can be done alongside feature work.

Feed the results into the existing workflow rather than letting them sit in a report:

- Add each item to `BACKLOG.md` as a `refactor` (or matching type) row via the **backlog-management** skill.
- Promote high-priority items to task files through the **task-workflow** skill before starting work.
