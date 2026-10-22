---
status: approved
issue: 1
author: olafkfreund
---

# Intent: Package and run Paperclip on NixOS

## Problem

Paperclip (https://github.com/paperclipai/paperclip, MIT) is an AI-agent
orchestration server with a web UI. Upstream ships it only as a Docker image
and an npm CLI (`paperclipai`, currently 2026.1012.0). There is no Nix
package or NixOS module, so on NixOS it can only run in a container, with no
declarative config, no systemd hardening and no reproducible version pin.

What upstream looks like (reviewed at commit 043f2514, 2026-10-21):

- pnpm 9 monorepo, Node >= 24.11, ~30 workspace packages (server, ui, cli,
  db, adapters, plugins). The server build emits `server/dist-runtime/index.mjs`
  and serves the built UI (`SERVE_UI=true`), default port 3100.
- A Rust daemon, `paperclip-runnerd` (Cargo workspace, ~3k-line lockfile,
  own `rust-toolchain.toml` pin), used by the runner/adapters.
- Database: `embedded-postgres` (default — downloads a Postgres binary via
  npm) or external Postgres via `DATABASE_URL`.
- Config: a JSON file (`PAPERCLIP_CONFIG`) plus ~50 env vars in
  `server/src/config.ts` and ~205 env vars across the server overall.
- The Docker image also installs agent CLIs at `@latest` (claude-code, codex,
  opencode, gemini-cli, kimi) that agents shell out to.
- Releases are tags like `v2026.916.1`; npm versions are `2026.MDD.N`.

## Proposed outcome

In this repo, a flake that provides:

1. `packages.<system>.paperclip` — a reproducible build of the server + UI
   (and `paperclipai` CLI) runnable with `nix run`.
2. `nixosModules.paperclip` — `services.paperclip` that runs it as a hardened
   systemd service with a dedicated user and state dir, using NixOS Postgres
   by default.
3. CI (GitHub Actions): lint (nixfmt/statix/deadnix), `nix flake check`
   including the build and a NixOS VM test that boots the service and gets
   HTTP 200 from it.
4. An update workflow that detects a new upstream release, bumps version and
   hashes, and opens a PR that must pass CI.

## Affected users and systems

- New repo only (`nixos-paperclip`); no existing hosts change.
- Consumers: any NixOS host that imports the module.
- Upstream: none (no patches sent upstream as part of this).

## Constraints

- Must build in the Nix sandbox: no network at build time, so pnpm deps go
  through a fixed-output `pnpmDeps` hash and Rust through `cargoLock`.
- Must not put secrets in the Nix store: secrets go through an
  `environmentFile` / systemd credentials.
- Must not install agent CLIs at `@latest` at runtime; they come from
  nixpkgs where they exist, or are left to the operator.
- Follow the `nixos-standards` skill and nixpkgs module conventions
  (`mkEnableOption`, `mkPackageOption`, RFC 42 `settings`).

## Pushback on scope (decide before spec)

- "All configuration options": typing 205 env vars by hand is a maintenance
  trap that rots with every upstream release. Proposal: typed options only
  for what NixOS must know (port, host, state dir, database, deployment mode,
  public URL, user/group, openFirewall), plus a freeform `settings`
  (rendered to the JSON config file) and `environment` attrset that pass
  every other upstream option through unchanged. Every upstream option is
  then reachable without us tracking it.
- Build from source vs the npm tarball: source is reproducible and matches
  upstream tags but is a heavy build (Rust daemon + full monorepo). The npm
  `paperclipai` package may be prebuilt and much simpler, but may not bundle
  the server/UI or the runner. Spec will verify which.
- Embedded Postgres downloads a binary at runtime, which fails on NixOS.
  Default to `services.postgresql` with peer auth; embedded mode not offered.

## Open questions

1. Issue number: this repo has no GitHub remote yet. I used `#1` and branch
   `feat/1-nixos-package-module`. Should I create `olafkfreund/nixos-paperclip`
   on GitHub and open issue #1 there?
2. Agree to the typed-core + freeform `settings`/`environment` approach
   instead of typing every option?
3. Which agent CLIs, if any, should the module put on the service's PATH
   (e.g. `claude-code`, `codex`, `gemini-cli` from nixpkgs)?
4. Update trigger: track upstream git tags (`v*`) or npm `paperclipai`
   releases? Schedule: daily?
5. Platforms: `x86_64-linux` only, or `aarch64-linux` too?
