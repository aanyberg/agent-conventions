---
name: python-coding-guidelines
description: Rules for simplifying code using Python idioms, comprehensions, operators, and eliminating unnecessary complexity
---

# Python Coding Guidelines

Python-specific idioms and type-system usage. Builds on the **Universal Code Rules** in `code-standards`; only Python-specific rules are listed here.

## Code Style

- Use `model_dump()` for Pydantic model serialization; reserve `TypeAdapter` with `mode='json'` for collections or external SDKs needing JSON-compatible primitives — `TypeAdapter.dump_python(mode='json')` guarantees primitive types (dicts/lists/strings) instead of `BaseModel` instances when required by external systems

## Type System

- Use `isinstance()` for type checking, not `hasattr()`, `getattr()`, `type(obj).__name__`, or discriminator field checks like `part_kind` — Enables proper type narrowing for static analysis and prevents fragile string-based comparisons that break during refactoring
- Use `Literal` types instead of plain `str` for fixed string value sets in parameters, fields, and return types — Makes valid values explicit in type signatures, enabling static type checkers to catch invalid strings at compile time and improving IDE autocomplete
- Create type aliases for complex types (3+ union branches, `dict[str, Any] | Callable` patterns, multi-value `Literal`s) or types used 2+ times — skip aliases for simple one-off internal types — Reduces duplication and improves readability for complex types while avoiding unnecessary abstraction that obscures simple inline hints
- Use `if TYPE_CHECKING:` blocks for optional dependency types with quoted hints — keeps package installable without all deps while preserving type safety — Prevents runtime import errors when optional dependencies aren't installed while maintaining proper type annotations instead of falling back to `Any`
- Type signatures to match runtime reality — if control flow (e.g., `match`/`case`, API contracts) guarantees only specific types reach a code path, narrow the annotation to exclude impossible types from unions — Prevents confusion, enables better type checking, and documents actual behavior rather than overly permissive signatures that suggest unreachable code paths
- Fix type errors properly instead of using `# type: ignore` or `# pyright: ignore` — use type annotations, narrowing, or `cast()` with explanatory comments — Prevents masking real type errors and makes code safer; when suppressions are genuinely needed (complex generics, tool limits), document with error codes and justification so reviewers understand the safety reasoning
- Remove redundant runtime checks when types already constrain the value — prevents noise and maintains type system trust — Redundant assertions (`assert x is not None` for non-`Optional` types, duplicate `isinstance()` checks, etc.) add visual clutter and imply the type system can't be trusted, making code harder to maintain
- Fix type definitions instead of using `cast()` — adjust generics or remove unnecessary unions to match runtime reality — Prevents masking structural type mismatches that indicate design problems; only use `cast()` when runtime logic guarantees safety but static analysis cannot narrow (e.g., after literal checks or known invariants)
- Don't add `| None` to `TypedDict` fields marked `total=False` or `NotRequired` — optionality is already expressed — Prevents redundant type declarations and makes it clear that omission (not None) is the intended optional behavior
- Remove `| None` from type annotations when values are guaranteed to be initialized or always provided — Prevents false optionality in types, making the API clearer and avoiding unnecessary None-checks that can never trigger

## Error Handling

- Use domain specific exceptions for surfacing errors to the user. These are generally defined in the projects `exceptions` module. Use the `raise x from y` pattern to make the cause clear.
- Use `!r` format specifier for identifiers in error messages (e.g., `f'Tool {name!r}'` not `f'Tool`{name}`'`) — Provides consistent, unambiguous quoting that clearly delimits values and handles edge cases like empty strings or special characters.
- Fail fast on explicit user config conflicts; gracefully fallback on internal/auto setting conflicts — Catching user mistakes early with clear errors prevents debugging confusion, while internal fallbacks enable cross-provider compatibility and system resilience when constraints are automatically inferred or propagated
- Inherit new exception types from existing base exceptions when semantically appropriate — Maintains backward compatibility so user code catching parent exceptions continues to work when new exception types are introduced
- Trust validated invariants and use defaults over assertions — reduces brittle failures and improves resilience — Assertions crash on unexpected states; defaults and graceful handling keep the system operational when assumptions don't hold, while trusting earlier validation stages avoids redundant defensive checks.

## Naming

- Use `UPPER_CASE` for module constants; prefix with `_` if internal (`_MAX_RETRIES`) — Distinguishes public API from internal implementation details and signals immutability

## Imports

- Follow google coding guidelines for imports - prefer to import the module instead of items. For example, when you need to use pydantics `BaseModel`, import `pydantic` and use `pydantic.BaseModel`. The `typing`, `typing_extensions`, `collections`, and their submodules are exceptions.
- Handle optional dependencies: (1) import inside functions to defer requirements, OR (2) use `try`/`except ImportError` at module level with helpful errors directing to install groups like `[web]`, `[bedrock]` — Keeps the package installable without all dependencies while providing clear guidance when optional features are used

## General

- Projects generally use `hatch` as a project/environment manager. Use the appropriate skill, check the projects documentation, or `pyproject.toml` for entrypoints for testing, static analysis, etc.

## Patterns & Idioms

- Use list comprehensions instead of for-loop-with-append patterns — more concise, readable, and often faster for transforming/filtering iterables into lists
- Use dict comprehensions instead of empty dict + loop — reduces boilerplate and signals intent more clearly
- Use `any()` instead of for-loops with boolean flags when checking if any element matches a condition — eliminates manual flag management and break statements
- Use `@cached_property` for expensive computed attributes — defers computation until first access and caches the result
- Omit parameters that match default values in function/constructor calls — makes non-default configuration more visible
- Eliminate single-use intermediate variables — reassign or return directly instead of creating `_filtered`, `_copy`, etc.
- Flatten nested `if` statements with no intervening code into `if condition1 and condition2:` — reduces nesting depth without changing logic
- Use `x or default` for fallback values instead of verbose if-else blocks — avoid when falsy values (0, `''`, `[]`, `None`) are semantically valid
- Define `TypeAdapter` instances at module level as constants — avoids repeated initialization overhead on every call
