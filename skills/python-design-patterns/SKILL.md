---
name: python-design-patterns
description: Python design patterns including KISS, Separation of Concerns, Single Responsibility, and composition over inheritance. Use this skill when designing a new service or component from scratch and choosing how to layer responsibilities, when refactoring a God class or monolithic function that has grown too large, when deciding whether to add a new abstraction or live with duplication, when evaluating a pull request for structural issues like tight coupling or leaking internal types, when choosing between inheritance and composition for a new class hierarchy, or when a codebase is becoming hard to test because of entangled I/O and business logic.
---

# Python Design Patterns

## When to Use This Skill

- Designing new components or services
- Refactoring complex or tangled code
- Deciding whether to create an abstraction
- Choosing between inheritance and composition
- Evaluating code complexity and coupling
- Planning modular architectures

## Patterns

- **KISS** — Choose the simplest solution that works. A plain dict beats a factory registry. Complexity must earn its place.
- **Single Responsibility (SRP)** — Each unit has one reason to change. HTTP parsing, business rules, and data access belong in separate classes.
- **Separation of Concerns** — Layer as: API handler → Service → Repository. Each layer depends only on layers below it; services must never import from handlers.
- **Composition Over Inheritance** — Build behavior by combining objects, not extending classes. Use constructor injection with Protocols.
- **Rule of Three** — Wait until you have three instances before abstracting. Duplication is often better than the wrong abstraction.
- **Function Size** — Functions over 20–50 lines likely serve multiple purposes. Extract when nesting exceeds 3 levels.
- **Dependency Injection** — Inject via constructor with Protocol-typed parameters. Production wires real implementations; tests wire fakes.
- **Don't expose internal types** — Use response schemas at API boundaries, not ORM models or internal dataclasses.
- **Don't mix I/O with business logic** — Business logic should be pure; data access belongs in repositories, not service methods.
- **Explicit over clever** — Readable code beats elegant code.
