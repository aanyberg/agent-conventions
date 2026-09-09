---
name: rust-best-practices
description: Use when reading or writing Rust files (.rs, Cargo.toml).
---

# Rust Best Practices

Follows the same type-first, functional, error-aware philosophy as `python-best-practices`, expressed through Rust's ownership, enums, traits, and `Result`. This skill covers language-specific idioms; pair it with `rust-coding-guidelines` for the rule list.

## Make Illegal States Unrepresentable

Rust's type system is the primary tool for correctness. Encode invariants so invalid states won't compile.

**Immutable domain models — ownership and `let` give you immutability by default:**

```rust
use std::time::SystemTime;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct User {
    pub id: UserId,
    pub email: String,
    pub name: String,
    pub created_at: SystemTime,
}

// No `mut`, no interior mutability — instances cannot be changed after construction.
```

**Discriminated unions are enums — model mutually-exclusive states directly:**

```rust
pub enum RequestState {
    Success { data: String },
    Failure { error: AppError },
}

fn handle_state(state: RequestState) {
    match state {
        RequestState::Success { data } => render(&data),
        RequestState::Failure { error } => show_error(&error),
    }
    // Exhaustive: adding a variant turns every match into a compile error until handled.
}
```

Prefer this over a struct with `Option` fields that "shouldn't" both be set — the enum makes the illegal combination impossible to construct.

**Newtype pattern for domain primitives — no accidental mixups:**

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UserId(String);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct OrderId(String);

fn get_user(id: &UserId) -> Option<User> {
    // The compiler rejects passing an `OrderId` here.
    todo!()
}
```

**Parse, don't validate — convert at the boundary into a type that cannot be invalid:**

```rust
pub struct Email(String);

impl Email {
    /// The only way to build an `Email`. Downstream code never re-checks.
    pub fn parse(raw: &str) -> Result<Self, AppError> {
        if raw.contains('@') {
            Ok(Email(raw.to_owned()))
        } else {
            Err(AppError::InvalidEmail { value: raw.to_owned() })
        }
    }
}
```

**Traits for structural/behavioral abstraction (Rust's answer to `Protocol`):**

```rust
use std::io::Read;

/// Accepts anything that can be read — no inheritance, static dispatch.
fn process_input<R: Read>(mut source: R) -> std::io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    source.read_to_end(&mut buf)?;
    Ok(buf)
}
```

## Error Handling

Use `Result<T, E>` and `?`. Define a domain error enum with `thiserror` for libraries; preserve the cause chain via `#[source]`/`#[from]`.

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("invalid email: `{value}`")]
    InvalidEmail { value: String },

    #[error("failed to read config")]
    Config {
        #[source]
        source: std::io::Error,
    },

    // `#[from]` auto-converts at the `?` site and records the cause.
    #[error("serialization failed")]
    Serde(#[from] serde_json::Error),
}
```

Propagate and enrich — `?` plus context is the equivalent of Python's `raise ... from err`:

```rust
fn load_config(path: &std::path::Path) -> Result<Config, AppError> {
    let raw = std::fs::read_to_string(path).map_err(|source| AppError::Config { source })?;
    let config = serde_json::from_str(&raw)?; // #[from] handles the conversion
    Ok(config)
}
```

For application/binary code where callers won't `match` on the variant, prefer `anyhow` with `.context(...)`:

```rust
use anyhow::Context;

fn run() -> anyhow::Result<()> {
    let raw = std::fs::read_to_string("config.json")
        .context("reading config.json")?;
    let _config: Config = serde_json::from_str(&raw)
        .context("parsing config.json")?;
    Ok(())
}
```

Reserve `unwrap`/`expect` for invariants that genuinely cannot fail, and state the reason:

```rust
let port: u16 = "8080".parse().expect("hardcoded port is a valid u16");
```

## Structured Logging

Use the `tracing` crate with structured fields rather than string interpolation — fields are captured as data, not baked into the message:

```rust
use tracing::{debug, info};

pub fn create_widget(name: &str) -> Widget {
    debug!(widget.name = name, "creating widget");
    let widget = Widget::new(name);
    info!(widget.id = %widget.id, "created widget");
    widget
}
```

Use `#[instrument]` to attach a span (with arguments) to a whole function:

```rust
#[tracing::instrument(skip(db))]
pub async fn fetch_user(db: &Db, id: &UserId) -> Result<User, AppError> {
    // Every event inside inherits the span, including `id`.
    db.get_user(id).await
}
```
