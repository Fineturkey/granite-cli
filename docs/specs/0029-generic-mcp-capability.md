# Plan: Generic MCP Server Capability

## Overview

Today the only capability that produces a `Binding::Mcp` is `vision-mcp`, which
starts its own in-process server. Users cannot register an MCP server they
already have (a local `npx` server, a hosted SaaS endpoint, etc.).

This adds an `mcp-server` capability type: a **configuration passthrough**.
The user supplies a standard MCP server definition (the `mcpServers` entry
shape shared by Claude Code, VS Code, Cursor, ...); `bind()` returns it as an
`McpBinding`; each launcher already knows how to render an `McpBinding` into
its native format. No server is run by granite-cli.

Much of the plumbing already exists:

- `McpBinding` (`Stdio` / `Http` / `Sse`) and `to_canonical_json()` in
  `src/capabilities/base.rs` are the de-facto standard shape.
- claude, bob, bobide, hermes, goose, opencode, and openclaw already consume it.
- Capability instances are per-`instance_id`, so each registered server is its
  own instance, and its `instance_id` is the MCP server name
  (`ToolName::Mcp { server }` already relies on this).

## Gaps in the existing plumbing

1. **SSE is never negotiated.** `mcp_binding_request()` offers only
   `{Stdio, Http}`. The request must become launcher-specific so each launcher
   declares what it can really register.
2. **Goose mis-maps SSE** to `--with-streamable-http-extension` and silently
   drops headers. With per-launcher requests, goose offers `{Stdio, Http}`
   only and an SSE server fails with a clear "no transport in common" error;
   headers on goose remain a warning.
3. **`McpBinding` has no auth beyond headers/env.** See Auth below.

## Config shape

`McpServerCapabilityConfig` (serde + schemars + `Validate`), mirroring the
standard entry:

| field | applies to | notes |
|---|---|---|
| `type` | all | `stdio` \| `http` \| `sse`; accepts aliases `streamable-http`, `streamableHttp`; inferred from `command`/`url` when absent on import |
| `command`, `args`, `env` | stdio | `command` required for stdio. `env` values are `Secret` |
| `url`, `headers` | http, sse | `url` required. `headers` values are `Secret` |
| `timeout` | all | ms, optional |
| `oauth` | http, sse | optional, see Auth |

Validation: stdio requires `command` and forbids `url`; http/sse require
`url` and forbid `command`; `url` must parse with an http(s) scheme.

`${VAR}` / `${VAR:-default}` expansion (a Claude Code `.mcp.json` convention)
is applied to `command`, `args`, `env`, `url`, `headers` at `bind()` time so a
pasted config keeps working and secrets can stay out of `config.json`.

The capability has no model/provider dependencies. No `Dependency::ExternalTool`
is declared: capability metadata is per type, not per instance, so it cannot
name each server's own `command`.

Because its config is the user's own, `CapabilityMetadata` gains
`auto_configurable` (false for `mcp-server`, true for every other type) and
setup discovery skips types where it is false, so the wizard and `--auto`
never recommend or create an `mcp-server`.

## Auth

MCP authorization is OAuth 2.1 (protected-resource metadata RFC 9728 ->
authorization-server metadata RFC 8414 -> dynamic client registration ->
browser PKCE flow -> token refresh). First version scope:

1. **Static credentials, all launchers.** Bearer tokens / API keys via
   `headers` (`Authorization: Bearer ...`), env vars for stdio. `Secret`-typed
   so prompts mask them and `Debug` never prints them.
2. **Launcher-native OAuth, pass-through.** Optional `oauth` block:
   `client_id`, `client_secret` (`Secret`), `callback_port`, `scope`. Added to
   the `Http`/`Sse` variants of `McpBinding` as
   `oauth: Option<McpOAuth>`. Launchers that run OAuth themselves render it;
   others ignore it and warn if the server then needs interactive auth.
   With no `oauth` block, a launcher's own discovery + dynamic registration
   still runs where it supports it.
3. **Out of scope:** granite-cli performing the flow, storing/refreshing
   tokens. Revisit as a follow-up spec if launcher coverage proves too thin.

### Launcher matrix

| launcher | stdio | http | sse | headers | native OAuth |
|---|---|---|---|---|---|
| claude | yes | yes | yes | yes | yes (`add-json` accepts an `oauth` block) |
| opencode | yes | yes | yes (as `remote`) | yes | unconfirmed: has `opencode mcp auth` for the flow, but its config schema for client hints was not checked; `oauth` is not rendered |
| bob / bobide | yes | yes | unconfirmed (`bob mcp add-json` stores `sse` but `mcp list` shows `http`) | yes | unconfirmed |
| hermes | yes | yes | unconfirmed (not tested) | yes | no |
| openclaw | yes | yes | yes | yes | no |
| goose | yes | yes | no | no | no |

Each launcher passes the transports in its column to
`mcp_binding_request(...)`. Implemented sets: claude, opencode and openclaw
offer Stdio/Http/Sse (claude confirmed by running `claude mcp add-json` with
`type: sse` and an `oauth` block, which it stored verbatim with camelCase
`clientId`/`callbackPort`); hermes, goose, bob and bobide offer Stdio/Http
only until SSE is confirmed for them. An SSE server bound to one of those
fails with an error naming the server and both transport sets.

## Registration UX

- `granite-cli capability setup mcp-server [instance_id]` uses the existing
  schema-driven prompt (secret fields masked).
- Existing `capability list/info/remove` and launcher enablement work
  unchanged since this is an ordinary capability type.

## Pre-filled setup is a separate spec

Bulk/pasted registration (`--from-json` / `--from-yaml`, including importing a
standard `{"mcpServers": {...}}` document) is generic across all setup
commands and lives in [0030](0030-setup-prefill.md). This spec does not
depend on it: `mcp-server` is set up through the existing schema prompt.

## Implementation steps

1. `base.rs`: add `McpOAuth`; add `oauth` to `McpBinding::{Http,Sse}`; update
   `to_canonical_json()` (emits `oauth` in the shape claude expects). Update
   the ~15 construction sites (all are `oauth: None`).
2. `src/capabilities/mcp_server.rs`: config, validation, `${VAR}` expansion,
   capability + metadata, `bind()` (intersects requested transports with the
   configured one; errors name both).
3. Register `mcp-server` in `CAPABILITY_REGISTRY`.
4. Make `mcp_binding_request` take the launcher's transport set; update each
   launcher; fix goose SSE mapping.
5. Render `oauth` in claude (via canonical JSON, verified). Other launchers
   ignore it; opencode rendering is deferred until its config schema is
   confirmed. Warning when a launcher drops `oauth` is not yet implemented.
6. Docs: README capability table via the `update-capability-table` skill.

## Testing

All unit tests are environment-independent (per AGENTS.md): config parsing and
validation per transport, alias handling, `${VAR}` expansion with an injected
env lookup, `bind()` transport intersection, canonical JSON with and without
`oauth`, per-launcher rendering of each transport, goose SSE rejection. No
test starts a real MCP server or touches the network.

## Open questions

- Should `${VAR}` expansion fail on unset variables with no default, or pass
  the literal through? Proposed: fail at bind with the variable name.
- bob/bobide SSE and OAuth behavior need confirmation against the installed
  `bob` before the matrix is final.
