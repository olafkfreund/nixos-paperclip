---
status: approved
issue: 1
intent: intent/2026-10-22-1-nixos-package-module.md
---

# Spec: Package and run Paperclip on NixOS

## Facts this design rests on

Checked against upstream tag `v2026.1012.0` (= npm stable `2026.1012.0`;
git tags and npm stable versions match one to one).

- `@paperclipai/server` on npm (354 MB unpacked) ships the compiled server
  (`dist/index.js`, which starts itself when run as main), the built UI
  (`ui-dist/`, found by `server/src/app.ts:1009`) and 7 bundled deps. It
  declares 50 more runtime deps, including `sharp` (native, prebuilt) and
  `embedded-postgres` (unused when `database.mode = "postgres"`).
- The `paperclip-runnerd` Rust daemon is not in the npm package. The server
  only names it as an adapter command (`server/src/adapters/registry.ts:577`),
  so it is optional.
- Config: JSON file at `$PAPERCLIP_CONFIG`, zod schema in
  `packages/shared/src/config-schema.ts` (sections `database`, `server`,
  `auth`, `storage`, `secrets`, `logging`, `telemetry`, `updates`, `llm`).
  Env vars override the file (`server/src/config.ts`).
- Auth secret: `BETTER_AUTH_SECRET` (fallback `PAPERCLIP_AGENT_JWT_SECRET`),
  needed when `deploymentMode = "authenticated"`.
- Health endpoint: `GET /api/health` (`server/src/app.ts:677`).
- nixpkgs (26.11) has `nodejs_24` 24.21.0. `pnpm_9`, which upstream pins
  (`packageManager: pnpm@9.15.4`), was removed from nixpkgs on 2026-08-03.

## Design

Flake with `packages`, `nixosModules`, `checks` and `formatter` for
`x86_64-linux` and `aarch64-linux`.

### Package: `package.nix`

`buildNpmPackage` built from the `@paperclipai/server` npm tarball:

- `src = fetchurl` of the registry tarball (pinned version and hash).
- The npm tarball has no lockfile, so this repo commits `package-lock.json`,
  generated with `npm install --package-lock-only --omit=dev` from the
  tarball's `package.json`, and copies it in `postPatch`. `npmDepsHash`
  pins it.
- `dontNpmBuild = true`, `nodejs = nodejs_24`. Installs to
  `$out/lib/node_modules/@paperclipai/server` and adds `bin/paperclip-server`
  (a `makeWrapper` around `node dist/index.js`, with `NODE_ENV=production`).
- `sharp`'s prebuilt binary is fixed up with `autoPatchelfHook` if it does
  not load as shipped.
- `passthru.tests.vm` points at the VM test; `meta` has license MIT,
  `mainProgram`, platforms.

### Module: `module.nix` → `services.paperclip`

Typed options, only what NixOS must know:

| Option | Default | Maps to |
| --- | --- | --- |
| `enable` | false | |
| `package` | flake's package (`mkPackageOption`) | |
| `user` / `group` | `paperclip` | static system user, needed for Postgres peer auth |
| `stateDir` | `/var/lib/paperclip` | `PAPERCLIP_HOME`, `HOME`, `StateDirectory` |
| `host` | `127.0.0.1` | `settings.server.host` |
| `port` | 3100 | `settings.server.port` |
| `openFirewall` | false | `networking.firewall.allowedTCPPorts` |
| `deploymentMode` | `authenticated` | `settings.server.deploymentMode` |
| `exposure` | `private` | `settings.server.exposure` |
| `publicUrl` | null | `settings.auth.publicBaseUrl` |
| `allowedHostnames` | `[]` | `settings.server.allowedHostnames` |
| `database.createLocally` | true | `services.postgresql` with `ensureDatabases`/`ensureUsers`, socket URL |
| `database.url` | null (required when `createLocally = false`) | `DATABASE_URL` |
| `environmentFile` | null | `EnvironmentFile`, for secrets and any env var |
| `extraPackages` | `[ git ]` | service `PATH`; this is where agent CLIs go |
| `settings` | `{}` | freeform (`pkgs.formats.json`), rendered to `config.json` |
| `environment` | `{}` | freeform env vars, every other upstream option |

The typed options write into `settings` with normal priority, so a user can
override any of them through `settings` with `mkForce`. Defaults that
differ from upstream: `database.mode = "postgres"`,
`updates.checkEnabled = false` (Nix manages versions),
`telemetry.enabled = false`, and storage, secrets and logging paths under
`stateDir`.

Auth secret: if `BETTER_AUTH_SECRET` is not set by `environmentFile`,
`ExecStartPre` generates `${stateDir}/auth-secret` once (mode 0600) and the
start script exports it. It never enters the Nix store.

Service: `wantedBy multi-user.target`, `after`/`requires`
`postgresql.service` when `createLocally`, `Restart=on-failure`, and the
usual hardening (`ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
`NoNewPrivileges`, `ReadWritePaths=stateDir`, restricted address families
and syscalls). No `MemoryDenyWriteExecute`, because Node's JIT needs W^X
pages.

Assertions: `database.url != null` when `createLocally = false`;
`publicUrl != null` when `exposure = "public"`.

### Answers to the intent's open questions (please confirm)

1. GitHub repo and issue: not created. The repo stays local, `#1` remains a
   placeholder, and pushing is your call.
2. Typed core plus freeform: as approved in the intent.
3. Agent CLIs: none by default. `extraPackages` defaults to `[ git ]`, and
   the README shows adding `claude-code`, `gemini-cli` or `opencode` from
   nixpkgs.
4. Updates: track npm `dist-tags.latest` of `@paperclipai/server` (stable
   only, never canaries), checked daily.
5. Platforms: both are exposed. CI builds and VM-tests `x86_64-linux` only,
   so `aarch64-linux` is untested.

### CI: `.github/workflows/`

- `ci.yml` (push and PR): `cachix/install-nix-action`, then
  `nix fmt -- --ci` (nixfmt), `statix check`, `deadnix --fail`, then
  `nix flake check -L`, which builds the package and runs the VM test.
  GitHub runners provide KVM.
- `update.yml` (daily cron and manual dispatch): runs `./update.sh`. If the
  version changed, `peter-evans/create-pull-request` opens a PR, and
  `ci.yml` gates it.
- `update.sh`: reads the latest version with `npm view`, rewrites the
  version and `hash` in `package.nix` (`nix-prefetch-url`), regenerates
  `package-lock.json`, and recomputes `npmDepsHash` with
  `prefetch-npm-deps`. Exits 0 with no changes when already current.

### Test: `tests/vm.nix`

A `nixosTest` with `services.paperclip.enable = true` and defaults (local
Postgres). It waits for the unit and port 3100, then checks that
`curl -f http://127.0.0.1:3100/api/health` succeeds. It also checks that the
generated `auth-secret` has mode 0600.

## Alternatives rejected

- **Build the monorepo from source** (`pnpm.fetchDeps` + cargo): upstream
  pins pnpm 9, which nixpkgs removed, and the build includes ~30 packages
  plus a Rust daemon the server does not need. It is fragile and slow, with
  no gain over the npm tarball that upstream publishes from the same tag.
- **Package the `paperclipai` CLI**: it is an interactive onboarding tool
  that imports `@paperclipai/server` itself. The module replaces its
  onboarding with declarative config. It could be a follow-up.
- **Embedded Postgres**: it extracts a downloaded binary into the state
  dir, which fails on NixOS (dynamic linking) and duplicates
  `services.postgresql`.
- **Typing every env var**: rejected in the intent.
- **Docker / `virtualisation.oci-containers`**: no reproducible pin, and
  `@latest` CLI tools inside the image.
- **Renovate or `nix-update` for updates**: `nix-update` does not
  regenerate a lockfile that lives outside the source. Three commands in a
  script are simpler.

## Risks

- **Generated lockfile drift**: our `package-lock.json` resolves semver
  ranges at generation time, not the versions upstream tested (upstream
  locks with pnpm). A bad transitive release could break a build or the
  runtime. The VM test catches startup failures, not feature bugs.
- **`sharp` native binary**: it may need `autoPatchelfHook` and `vips`
  libs. Found at build time.
- **Read-only config file**: `config.json` lives in the Nix store. If the
  server writes back to it (onboarding/doctor), that fails. Mitigation if
  the VM test or a manual run shows writes: copy the file into `stateDir` in
  `ExecStartPre` instead.
- **Package closure ~400 MB+**: that is the cost of bundled node_modules.
- **Upstream release cadence** (several stable releases a month): the
  update PRs are frequent and each runs the VM test.
- **First admin**: in `authenticated` mode, the first user claims admin
  through the UI (`server/src/first-admin-claim.ts`). The README documents
  it. Nothing to automate.

## Verification

1. `nix build .#paperclip` succeeds, and `result/bin/paperclip-server`
   exists.
2. `nix flake check -L` passes: formatter, statix, deadnix, package build,
   and the VM test (`/api/health` returns 200 with local Postgres).
3. `./update.sh` with the current version makes no diff. Run against an
   older pinned version, it produces a diff that builds.
4. `actionlint` passes on both workflow files.
