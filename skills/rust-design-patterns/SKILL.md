---
name: rust-design-patterns
description: Rust design patterns including KISS, Separation of Concerns, Single Responsibility, ownership-driven layering, and composition via traits. Use this skill when designing a new service or component from scratch and choosing how to layer responsibilities, when refactoring a God struct or monolithic function that has grown too large, when deciding whether to add a new trait or generic abstraction or live with duplication, when evaluating a pull request for structural issues like tight coupling or leaking internal types, when choosing between generics and trait objects, when deciding what to own versus borrow, or when a codebase is becoming hard to test because of entangled I/O and business logic.
---

# Rust Design Patterns

## When to Use This Skill

- Designing new components or services
- Refactoring complex or tangled code
- Deciding whether to create an abstraction (trait, generic, or newtype)
- Choosing between generics (static dispatch) and trait objects (dynamic dispatch)
- Deciding what to own versus borrow at an API boundary
- Evaluating code complexity, coupling, and testability
- Planning modular crate and module architectures

## Patterns

- **KISS** — Choose the simplest solution that works. A plain `enum` + `match` beats a trait-object registry. A free function beats a trait with one impl. Complexity must earn its place.
- **Single Responsibility (SRP)** — Each type/module has one reason to change. Wire parsing, business rules, and persistence belong in separate types — not one God struct.
- **Separation of Concerns** — Layer as: handler → service → repository. Each layer depends only on layers below via traits; the service must never know about HTTP types or SQL rows.
- **Composition Over Inheritance** — Rust has no inheritance by design. Build behavior by combining structs and implementing traits; inject collaborators as fields, not by extending a base type.
- **Parse, Don't Validate** — Push validation to the boundary and return a type that cannot be invalid (newtype, validated struct, enum). Downstream code trusts the type instead of re-checking.
- **Make Illegal States Unrepresentable** — Model mutually-exclusive states as `enum` variants, not structs of `Option` fields. Let the type system reject invalid combinations at compile time.
- **Rule of Three** — Wait until you have three instances before abstracting into a trait or generic. Duplication is cheaper than the wrong abstraction — and the wrong trait is expensive to unwind.
- **Generics over trait objects by default** — Prefer `fn f<T: Trait>(x: T)` (static dispatch, monomorphized, inlinable). Reach for `Box<dyn Trait>` / `&dyn Trait` only for heterogeneous collections, to break compile-time coupling, or to shrink binary/compile size.
- **Own vs borrow deliberately** — Take `&T` when you only read, `&mut T` when you mutate in place, `T` only when you must store or consume it. Signatures communicate intent; gratuitous ownership forces needless clones on callers.
- **Newtype for meaning and invariants** — Wrap primitives (`struct Meters(f64)`) to prevent mixups and to hang validation/behavior off a domain type instead of a bare `String`/`u64`.
- **Function Size** — Functions over 20–50 lines likely serve multiple purposes. Extract when nesting (especially `match`/`if let` pyramids) exceeds 3 levels — `?` and combinators usually flatten them.
- **Dependency Injection via traits** — Define a trait for each collaborator; inject it as a generic field or `Box<dyn Trait>`. Production wires real impls; tests wire fakes — no mocking framework required.
- **Don't expose internal types** — Use dedicated request/response (DTO) types at API boundaries, not your domain structs or DB row types. Implement `From` to convert between layers.
- **Don't mix I/O with business logic** — Keep core logic pure and synchronous over owned/borrowed data; confine `async`, filesystem, network, and DB calls to the edges (repositories, adapters). Pure cores are trivially testable.
- **Errors as types, not strings** — Model failure modes as a `thiserror` enum per layer; convert across boundaries with `#[from]`. Reserve `anyhow` for the application edge.
- **Explicit over clever** — Readable code beats elegant code. Avoid deep generic gymnastics and macro magic when a plain function will do.

## Composition & Dependency Injection Example

```rust
// A trait per collaborator — the seam for testing and swapping implementations.
pub trait UserRepository {
    fn find(&self, id: &UserId) -> Result<Option<User>, RepoError>;
}

// The service depends on the abstraction, not a concrete DB type.
pub struct UserService<R: UserRepository> {
    repo: R, // composition: the repo is a field, not a base class
}

impl<R: UserRepository> UserService<R> {
    pub fn new(repo: R) -> Self {
        Self { repo }
    }

    // Pure business logic — no I/O details leak in here.
    pub fn display_name(&self, id: &UserId) -> Result<String, RepoError> {
        Ok(self
            .repo
            .find(id)?
            .map(|u| u.name)
            .unwrap_or_else(|| "anonymous".to_owned()))
    }
}

// Production wires the real repo; tests wire a fake — same generic, no mocks.
#[cfg(test)]
mod tests {
    use super::*;

    struct FakeRepo(Option<User>);
    impl UserRepository for FakeRepo {
        fn find(&self, _id: &UserId) -> Result<Option<User>, RepoError> {
            Ok(self.0.clone())
        }
    }

    #[test]
    fn falls_back_to_anonymous_when_user_missing() {
        let service = UserService::new(FakeRepo(None));
        assert_eq!(service.display_name(&UserId::new("x")).unwrap(), "anonymous");
    }
}
```
