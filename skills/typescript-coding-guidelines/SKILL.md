---
name: typescript-coding-guidelines
description: Rules for TypeScript and JavaScript code — idioms, type system usage, error handling, naming, imports, and eliminating unnecessary complexity. Use when reading or writing .ts, .tsx, .js, or .jsx files.
---

# TypeScript & JavaScript Coding Guidelines

Applies to all `.ts`, `.tsx`, `.js`, and `.jsx` files. Builds on the **Universal Code Rules** in `code-standards`; only TypeScript/JavaScript-specific rules are listed here. TypeScript-only rules are marked **[TS]**.

## Type System [TS]

- Use `instanceof` for class-based type narrowing; use discriminated unions with a `kind` or `type` literal field for sum-type narrowing — Enables proper type narrowing for static analysis and prevents fragile duck-typing
- Use `unknown` instead of `any` — forces explicit narrowing before use, catching errors at compile time rather than runtime
- Avoid `as` type assertions except when runtime logic guarantees safety and static analysis cannot narrow (e.g., after a literal check or known invariant) — use type guards or discriminated unions instead; document the safety reasoning when `as` is genuinely necessary
- Use `satisfies` to validate an expression against a type without widening the inferred type — preserves literal types while catching structural mismatches at the point of definition
- Use `as const` assertions for readonly literal tuples and objects — prevents widening to mutable primitive types
- Use `Literal` union types for fixed string/number value sets in parameters, fields, and return types — Makes valid values explicit in signatures and enables static catch of invalid values
- Create type aliases for complex types (3+ union branches, object types used 2+ times) — reduces duplication and improves readability; skip aliases for simple one-off internal types
- Use `interface` for extensible object shapes (declaration merging, class `implements`); use `type` for unions, intersections, mapped types, and aliases — matches the intended extension model of each construct
- Use `readonly` on arrays (`readonly T[]`) and object properties that must not be mutated — makes immutability intent explicit and catches accidental writes at compile time
- Use `never` to enforce exhaustive checks in `switch`/`if`-else chains over discriminated unions — a compile-time guarantee that all cases are handled
- Remove `| undefined` from fields when values are guaranteed to be initialized — prevents false optionality and unnecessary non-null checks
- Avoid `@ts-ignore`; use `@ts-expect-error` only when unavoidable, always with a comment explaining why the suppression is safe and what error it hides
- Fix type errors properly — use type annotations, narrowing, or `as` with explanatory comments — prevents masking real type errors that indicate structural problems
- **`strict: true` is non-negotiable** — it enables `noImplicitAny`, `strictNullChecks`, `strictFunctionTypes`, and related checks; never disable it project-wide

## Error Handling

- Use domain-specific error classes extending `Error` — set `this.name` in the constructor for clear stack traces and `instanceof` checks
- Use the `cause` option when re-throwing: `throw new AppError("message", { cause: err })` — preserves the original stack trace and error chain
- Avoid swallowing errors in `.catch(() => {})` — at minimum log them with enough context to diagnose the issue later

## Naming

- Use `camelCase` for variables, functions, and methods; `PascalCase` for classes, interfaces, types, and enums; `UPPER_CASE` for module-level constants (`const MAX_RETRIES = 3`)
- Prefix internal module constants with `_` when they are not part of the public export surface (`const _CACHE_TTL_MS = 60_000`)

## Imports

- Prefer named exports over default exports — named exports improve refactoring support, IDE discoverability, and make re-exporting explicit
- Use barrel files (`index.ts`) to define the public API of a module — export only what consumers need; do not re-export internal implementation details
- Avoid circular imports — if two modules depend on each other, extract shared logic into a third module
- Group imports consistently: external packages first, then internal modules (`@/`, `~/`, relative), separated by a blank line; enforce with ESLint's `import/order` rule or Biome

## Testing

- Prefer `vi.fn()` / `jest.fn()` stubs over full module mocks when testing units in isolation — avoids over-specification and keeps tests resilient to refactoring

## General

- Use `pnpm` by default unless `package.json` scripts or project docs specify `npm` or `yarn`
- Run `eslint` and `prettier` (or `biome`) before committing — enforce via pre-commit hooks or CI; never disable rules project-wide without a documented reason
- Prefer `const` over `let`; never use `var` — `const` communicates immutability of the binding and prevents accidental reassignment
- Use optional chaining (`?.`) and nullish coalescing (`??`) instead of manual null guards — more concise and avoids incorrectly coalescing on `0`, `""`, or `false`
- Use `structuredClone()` for deep cloning plain objects instead of `JSON.parse(JSON.stringify(...))` — handles more types correctly and is faster in modern runtimes
