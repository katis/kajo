# ADR 0002: Repository layout

Date: 2026-11-01
Status: accepted

## Context

A single developer, one language for VM and shells, plus Smalltalk sources
that must live in git. The AGENTS.md principles ask for experiments before
designs lock in, and for modules that hide decisions.

## Decision

One repository, one root SwiftPM package, Xcode projects for the shells, and
dedicated directories for Smalltalk sources, experiments and decisions.

```
Package.swift          root package: KajoVM library, kajo CLI, tests
Sources/KajoVM/        the VM core, strict memory safety on
Sources/kajo/          headless CLI: boot an image, run tests, serve the dev protocol
Tests/KajoVMTests/     Swift Testing suite for the VM
kernel/                Smalltalk sources, text format to be decided
apps/                  Xcode projects for the macOS and iOS shells, depending on the root package
                       (since module 11a their hosts are the root package's KajoApp library, and
                       `kajo new` writes a developer's own app project anywhere else)
experiments/           throwaway spikes, one directory each, deletable
docs/CONTEXT.md        domain vocabulary
docs/adr/              one decision per file, numbered
references/            read-only clones, gitignored, listed in references/MANIFEST.md
justfile               build, test, run, bench, iOS check
```

## Reasons

- The package is the unit Xcode consumes, so the shells pick up the VM as a
  local dependency with no packaging step.
- Experiments stay in the tree so decisions can point at evidence.
- The image is a build artifact and is never committed; `kernel/` holds the
  sources it is built from.

## Open

- The Smalltalk source text format (Tonel-like, one class per file, is the
  default assumption).
- Whether the shells share a single Xcode project or have one each.
- Whether `KajoVM` splits into several targets once the object memory, GC and
  scheduler boundaries have proven themselves.
