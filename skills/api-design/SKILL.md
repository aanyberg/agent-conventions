---
name: api-design
description: Rules for designing public APIs, managing visibility, backwards compatibility, and API patterns
---

# API Design & Interfaces

**When to check**: designing or modifying public APIs, parameters, or class interfaces.

## Rules

- Prefix implementation details with `_` and exclude from `__all__` — keeps the public surface minimal and frees internal code from backward-compatibility obligations.
- Export commonly-used types/classes from the top-level `vcc.<PROJECT>` package — simplifies user imports and lets internal structure be refactored without breaking consumers.
- Put a `_: KW_ONLY` marker before optional fields in dataclasses/Pydantic models — callers can't pass defaults positionally, so fields can be added or reordered without breakage.
- Prefer instance methods when accessing `self` or enabling polymorphism; use module-level functions when no instance state is needed — extract shared logic to private top-level helpers to avoid cross-class duplication.
- Keep old names as deprecated aliases when renaming public API elements — lets users migrate gradually instead of breaking on upgrade.
- Return new collections from transform functions instead of mutating inputs — avoids surprising side effects (exceptions: performance-critical paths or functions named `update_*`/`*_inplace`).
- Don't access or modify private attributes (`_prefixed`) — use public APIs, properties, or constructor parameters, so internal changes don't break callers.
