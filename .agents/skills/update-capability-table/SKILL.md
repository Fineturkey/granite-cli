---
name: update-capability-table
description: Use this skill any time a launcher or capability is added, removed, or has its supported_capabilities changed, to keep the Capability Support table in README.md in sync with the source code.
---

# Update Capability Table Skill

This skill regenerates the **Capability Support** matrix in `README.md` by
parsing the launcher and capability source files. It is the authoritative way
to keep the table in sync — never edit the table by hand.

## When to Use This Skill

- A new launcher is registered in `src/launchers/mod.rs`
- A new capability is registered in `src/capabilities/mod.rs`
- An existing launcher's `supported_capabilities` set changes
- A capability's `BindingType` changes
- A capability's metadata `name` or `description` changes
- The CI step `Check capability table is up to date` fails on a PR

## Prerequisites

- `bash` (macOS system bash is sufficient — no Homebrew needed)
- Standard Unix tools: `grep`, `sed`, `awk` — all present on macOS and Linux

No internet connection required. Everything is read from local source files.

## Quick Start

```bash
# Regenerate the table in README.md
./scripts/update-capability-table.sh

# Verify it is up to date (CI mode — exits 1 if stale)
./scripts/update-capability-table.sh --check

# Review what changed
git diff README.md
```

## What the Script Does

1. Reads launcher ids and their modules (in registration order) from
   `src/launchers/mod.rs`
2. Reads capability ids and their modules (in registration order) from
   `src/capabilities/mod.rs`
3. Finds each source file from the module named in its
   `factory.register::<module::Type>("id")` line (`<module>.rs` or
   `<module>/mod.rs`) -- there is no per-id file list to maintain
4. For each launcher, extracts its `supported_capabilities: HashSet::from([...])`
5. For each capability, extracts `supported_binding_types`, `name` and
   `description` from its `fn metadata()`, or, for sub-agents declared with
   `declare_sub_agent_*!`, from the macro call (name and description) and the
   macro definition (binding types). A `name`/`description` may be a string
   literal or a `const X: &str` in the same file
6. Lists the binding types from the `define_bindings!` block in
   `src/capabilities/base.rs`
7. Generates a markdown matrix and description table, and replaces the block
   in `README.md` between `<!-- capability-table-start -->` and
   `<!-- capability-table-end -->`

A capability appears in a launcher's column when they share at least one
binding type. The script warns on stderr when it cannot find a capability's
binding types, name or description, rather than emitting an empty cell
silently.

## Adding a New Launcher

1. Create `src/launchers/<module>.rs` and implement `fn metadata() -> LauncherMetadata`
   with `supported_capabilities: HashSet::from([BindingType::X, ...])`
2. Register it in `src/launchers/mod.rs`:
   `factory.register::<your_module::YourLauncher>("your-id");`
3. Run `./scripts/update-capability-table.sh`
4. Commit `README.md` alongside your launcher source

## Adding a New Capability

1. Create `src/capabilities/<module>.rs` (or `<module>/mod.rs`) and implement
   `fn metadata() -> CapabilityMetadata` with the capability's `name`,
   `description`, and `supported_binding_types`
2. Register it in `src/capabilities/mod.rs`, naming the module:
   `factory.register::<your_module::YourCapability>("your-id");`
3. If it fills a new `BindingType`, add a one-line description for it to
   `binding_type_blurb` in `scripts/update-capability-table.sh` (it is listed
   by name without one)
4. Run `./scripts/update-capability-table.sh`
5. Commit `README.md` alongside your capability source

## CI Enforcement

The `rust` job in `.github/workflows/ci.yml` runs:

```bash
bash scripts/update-capability-table.sh --check
```

This step fails if `README.md` is stale, blocking the PR until the table is
regenerated and committed.

## Related Files

- [`scripts/update-capability-table.sh`](../../../scripts/update-capability-table.sh) — the generator script
- [`src/launchers/mod.rs`](../../../src/launchers/mod.rs) — launcher registration
- [`src/capabilities/mod.rs`](../../../src/capabilities/mod.rs) — capability registration
- [`README.md`](../../../README.md) — contains the generated table
- [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) — CI enforcement step
