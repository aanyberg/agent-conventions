---
name: rust-coding-guidelines
description: Rules for Rust code — idioms, type system usage, error handling, naming, modules, and eliminating unnecessary complexity. Use when reading or writing .rs files or Cargo.toml.
---

# Rust Coding Guidelines

Applies to all `.rs` files and `Cargo.toml`. Builds on the **Universal Code Rules** in `code-standards`; only Rust-specific rules are listed here. Pairs with `rust-best-practices` (worked examples) and `rust-design-patterns`.

## Code Style

- Compile static `Regex` patterns once with `LazyLock` (or `once_cell::Lazy`) — avoids recompilation overhead on repeated calls
- Prefer iterator chains (`.iter().map().filter().collect()`) over manual `for`-loop-with-push — more concise, often faster, and signals intent
- Let `rustfmt` own formatting — never hand-format; run it before committing and never `#[rustfmt::skip]` without a documented reason
- Prefer expression-oriented code: return the value of an `if`/`match`/block directly instead of mutating a binding then returning it

## Type System

- Make illegal states unrepresentable — model mutually-exclusive states as `enum` variants carrying their data, not structs full of `Option` fields that "shouldn't" coexist
- Use the newtype pattern (`struct UserId(String)`) for domain primitives — the compiler prevents passing an `OrderId` where a `UserId` is expected, unlike a bare `String`
- Parse, don't validate — convert untrusted input into a validated type at the boundary via `TryFrom`/a fallible constructor, so downstream code receives a type that *cannot* be invalid
- Prefer `enum` + `match` for sum types; exhaustive `match` gives a compile error when a variant is added — avoid a catch-all `_ =>` arm on domain enums you own, so new variants surface every site that must handle them
- Accept the most general type that works: take `&str` over `&String`, `&[T]` over `&Vec<T>`, `impl IntoIterator` / `impl AsRef<Path>` for flexible APIs
- Derive `Debug` on every public type; derive `Clone`, `PartialEq`, `Eq`, `Hash` when semantically meaningful — never hand-write what a derive provides
- Use `#[non_exhaustive]` on public enums/structs that may grow — forces downstream `match`es to keep a wildcard arm, preserving backward compatibility when variants/fields are added
- Prefer borrowing (`&T`) in function signatures; take ownership only when the function genuinely needs to store or consume the value
- Reach for generics with trait bounds for static dispatch; use `dyn Trait` (boxed) only when you need heterogeneous collections or to break compile-time coupling
- Avoid `unsafe`; when genuinely required, isolate it in the smallest possible function with a `// SAFETY:` comment justifying every invariant relied upon
- Avoid stringly-typed code — model fixed value sets as enums, not `&str` constants compared by equality

## Error Handling

- Use `Result<T, E>` for recoverable errors and the `?` operator to propagate — never `unwrap()`/`expect()` in library or production paths
- Reserve `panic!`, `unwrap`, and `expect` for unreachable invariants and tests; when used, `expect("reason")` must state the invariant that makes it infallible
- Define domain error enums with `thiserror` for libraries — one variant per failure mode, with `#[from]` for automatic conversion and `#[source]` to preserve the cause chain
- Use `anyhow` (with `.context("...")`) for application/binary code where callers won't match on the error variant — add context at each layer so the chain reads top-down
- Add context when propagating across an abstraction boundary — a bare `?` that surfaces a low-level IO error to a user is worse than `.context("reading config from {path}")`
- Return `Result` instead of sentinel values; use `Option<T>` for genuine absence (not failure), and convert with `.ok_or(...)` / `.ok_or_else(...)`
- Never silently discard a `Result` — handle it, propagate with `?`, or explicitly `let _ =` with a comment explaining why the error is safe to ignore

## Naming

- `snake_case` for functions, variables, modules, and files; `PascalCase` for types, traits, and enum variants; `SCREAMING_SNAKE_CASE` for `const`/`static`
- Prefix internal items with nothing but keep them private (no `pub`) — Rust's module visibility, not naming, marks the public surface; use `pub(crate)` for crate-internal sharing
- Getters drop the `get_` prefix (`fn name(&self)`, not `fn get_name(&self)`); conversions follow convention: `as_` (cheap borrow), `to_` (expensive/owned), `into_` (consuming)

## Imports & Modules

- Group `use` statements: `std` first, then external crates, then crate-local (`crate::`, `super::`, `self::`), separated by blank lines — `rustfmt`'s `group_imports` enforces this
- Import the item you use (`use std::collections::HashMap;` then `HashMap`) rather than fully-qualifying at call sites; for trait methods, import the trait
- Avoid glob imports (`use foo::*`) except for preludes and inside `#[cfg(test)] mod tests` (`use super::*`)
- Define a module's public API explicitly with `pub use` re-exports at the crate root — let internal module structure stay refactorable without breaking consumers
- Keep `mod` declarations and visibility tight — expose the minimum; default to private and widen deliberately

## Testing

- Put unit tests in a `#[cfg(test)] mod tests` block in the same file; put integration tests in `tests/` exercising the public API only
- Prefer `assert_eq!`/`assert!` with a message; use `#[should_panic(expected = "...")]` to pin the panic reason; reach for `proptest` when input space is large

## General

- Use `cargo` as the single entrypoint: `cargo build`, `cargo test`, `cargo clippy`, `cargo fmt` — check the project's docs for any wrapper before assuming
- Run `cargo clippy` before committing and fix lints rather than `#[allow(...)]`-ing them; an `#[allow]` must carry a comment explaining why the lint is wrong here
- Set `#![deny(warnings)]` or wire `-D warnings` in CI; never disable lints crate-wide without a documented reason
- Prefer immutability — `let` over `let mut`; introduce `mut` only where a value genuinely changes
- Pin the edition in `Cargo.toml` and keep dependencies minimal — each crate is a maintenance and audit surface

## Patterns & Idioms

- Use `if let` / `let ... else` for single-variant extraction instead of a full `match` with a throwaway arm
- Use combinators (`map`, `and_then`, `unwrap_or_else`, `filter_map`) over manual `match` ladders on `Option`/`Result` when they read more clearly
- Use `?` to flatten nested error handling instead of pyramids of `match`
- Prefer `collect()` into the target type (`Result<Vec<_>, _>`, `HashMap<_, _>`) over building and pushing in a loop
- Use `impl Trait` in argument and return position to avoid naming complex iterator/closure types
- Use `derive`d `Default` + struct-update syntax (`Foo { x, ..Default::default() }`) over hand-written constructors with many optional fields; reach for the builder pattern when there are many optional fields with interdependencies
- Use `Cow<str>` when a function sometimes returns borrowed and sometimes owned data, to avoid forcing an allocation
- Implement `From`/`TryFrom` for conversions rather than ad-hoc `to_x` helpers — they compose with `?` and `.into()`
