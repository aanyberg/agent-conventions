---
name: hatch-workflow
description: Workflow for working with hatch based VCC projects. Contains entrypoints for running tests, static analysis and building.
---

# Hatch command agenda

This file lists the common `hatch` commands you can use in this repository to **test**, **type-check/lint/format**, and **build** artifacts like **wheels**, **docs**, and the **container**.

> Notes:
>
> - Commands are shown as you can run them from the repository root.
> - Some environments are matrix-based (e.g. `hatch-test`); you may see Hatch create env names like `hatch-test.py3.10-highest`.

---

## 1) Testing

### Run all tests (default selection)

```bash
hatch test
```

### Run all tests with coverage enabled (as configured)

```bash
hatch test -c
```

### Run tests without xdist parallelism (useful for debugging / CI parity)

```bash
hatch test -c -n0
```

### Run a specific test file (example)

```bash
hatch test -c -n0 tests/unittest/test_constraint.py
```

---

## 2) Static analysis (linting/formatting/docstring lint)

### Lint and format with autofixes

```bash
hatch fmt
```

### Docstring lint only

```bash
hatch run hatch-static-analysis:lint-doc-string
```

### Lint (check) only

```bash
hatch fmt --check --linter
```

### Lint with autofixes

```bash
hatch fmt --linter
```

### Format check (no changes)

```bash
hatch fmt --check --formatter
```

### Format apply (write changes)

```bash
hatch fmt --formatter
```

---

## 3) Type checking (mypy)

### Run mypy (installs any missing stubs automatically)

```bash
hatch run types:check
```

### Type-check a subset (example: only `src/vcc`)

```bash
hatch run types:check src/vcc
```

---

## 4) Build Python artifacts (wheel / sdist)

### Build both sdist + wheel

```bash
hatch build
```

### Clean build (recommended for release artifacts)

```bash
hatch build -c
```

### Build only the wheel

```bash
hatch build -c -t wheel
```

### Build only the sdist

```bash
hatch build -c -t sdist
```

---

## 5) Documentation (Sphinx)

### Generate API docs (sphinx-apidoc) into `docs/code`

```bash
hatch run docs:gen-api
```

### Build HTML documentation into `tmp/docs/build/html`

```bash
hatch run docs:build
```

### Serve docs with live reload (sphinx-autobuild)

```bash
hatch run docs:serve
```
