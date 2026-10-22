---
status: approved
issue: 1
spec: spec/2026-10-22-1-nixos-package-module.md
---

# Plan: Package and run Paperclip on NixOS

## Approved decisions (from the spec)

- Package the **npm tarball** of `@paperclipai/server` (start at
  `2026.1012.0`) with `buildNpmPackage` and `nodejs_24`. Do not build the
  monorepo from source, because upstream pins pnpm 9 and nixpkgs removed it.
- The tarball has no lockfile. Commit `package-lock.json`, generated with
  `npm install --package-lock-only --omit=dev --ignore-scripts` from the
  tarball's `package.json`, and copy it in `postPatch`.
- Entry point: `node dist/index.js`, which starts itself when run as main.
  The UI is in `ui-dist/` inside the package and is found automatically.
- Module `services.paperclip`. Typed options: `enable`, `package`, `user`,
  `group` (both `paperclip`), `stateDir` (`/var/lib/paperclip`), `host`
  (`127.0.0.1`), `port` (3100), `openFirewall` (false), `deploymentMode`
  (`"local_trusted" | "authenticated"`, default `authenticated`), `exposure`
  (`"private" | "public"`, default `private`), `publicUrl` (null),
  `allowedHostnames` (`[]`), `database.createLocally` (true), `database.url`
  (null), `environmentFile` (null), `extraPackages` (`[ pkgs.git ]`),
  `settings` (freeform JSON), `environment` (freeform attrs of str).
- Typed options are written into `settings` at normal priority, so users
  override them with `mkForce`. Module defaults use `mkDefault`:
  `database.mode = "postgres"`, `updates.checkEnabled = false`,
  `telemetry.enabled = false`, `logging = { mode = "file"; logDir =
  "${stateDir}/logs"; }`, `storage.localDisk.baseDir`,
  `secrets.localEncrypted.keyFilePath` and `database.backup.dir` under
  `stateDir`, and `"$meta" = { version = 1; updatedAt =
  "1970-01-01T00:00:00Z"; source = "configure"; }`.
- Config schema facts (`packages/shared/src/config-schema.ts`): required
  top-level keys are `$meta`, `database`, `logging` (`mode` required),
  `server` and `telemetry`. The schema is `.passthrough()`, so unknown keys
  are allowed.
- Database: when `createLocally`, `services.postgresql.enable`,
  `ensureDatabases = [ "paperclip" ]`, `ensureUsers = [{ name = cfg.user;
  ensureDBOwnership = true; }]`, and env
  `DATABASE_URL=postgresql:///paperclip?host=/run/postgresql`. Otherwise
  `DATABASE_URL = cfg.database.url`.
- Auth secret: unless `environmentFile` sets `BETTER_AUTH_SECRET`,
  `ExecStartPre` creates `${stateDir}/auth-secret` once (umask 077,
  `head -c 48 /dev/urandom | base64`), and the start script exports it.
  It never goes in the store.
- Environment: `PAPERCLIP_HOME = stateDir`, `HOME = stateDir`,
  `PAPERCLIP_CONFIG` = the rendered store file, `NODE_ENV = production`,
  `SERVE_UI = "true"`, then `cfg.environment` merged on top.
- Assertions: `createLocally || url != null`; `exposure == "public" ->
  publicUrl != null`.
- Hardening: `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
  `PrivateDevices`, `NoNewPrivileges`, `ProtectKernel*`,
  `ProtectControlGroups`, `RestrictNamespaces`, `LockPersonality`,
  `RestrictAddressFamilies = AF_UNIX AF_INET AF_INET6`,
  `SystemCallFilter = @system-service`, `ReadWritePaths = stateDir`. **No**
  `MemoryDenyWriteExecute`, because the Node JIT needs it off.
- Updates track npm `dist-tags.latest` (stable only), checked daily. The
  update PR is opened by `peter-evans/create-pull-request` and gated by CI.
- Platforms: `x86_64-linux` and `aarch64-linux`. CI tests `x86_64` only.
- Not doing: GitHub repo/issue creation, the `paperclipai` CLI, the
  `paperclip-runnerd` Rust daemon, embedded Postgres, agent CLIs by default.

## Steps

1. `flake.nix`, `.gitignore`: inputs `nixpkgs` (`nixos-unstable`). Outputs
   for both systems: `packages.{paperclip,default}` (callPackage
   `./package.nix`), `nixosModules.{paperclip,default}` (`./module.nix`,
   with `services.paperclip.package` defaulting to this flake's package via
   `mkDefault`), `formatter = pkgs.nixfmt-tree`, and `checks` (filled in by
   steps 2 and 4, plus `lint`: a `runCommand` running `statix check` and
   `deadnix --fail` on the source). `.gitignore` gets `result*`.
   → verify by `nix flake show` and `nix flake lock`.
   Traps: new files must be `git add`ed or flakes cannot see them.

2. `package-lock.json`, `package.nix`: unpack the tarball in the
   scratchpad, run the npm command above, copy the lockfile to the repo
   root. `package.nix`: `buildNpmPackage { pname = "paperclip"; version;
   src = fetchurl { url = ".../@paperclipai/server/-/server-${version}.tgz";
   hash; }; postPatch = "cp ${./package-lock.json} package-lock.json";
   npmDepsHash; nodejs = nodejs_24; dontNpmBuild = true; npmFlags = [
   "--omit=dev" ]; }`. `installPhase` copies to
   `$out/lib/node_modules/@paperclipai/server` and `makeWrapper`s
   `$out/bin/paperclip-server` (`--add-flags dist/index.js`,
   `--set-default NODE_ENV production`). `meta`: MIT, `mainProgram`, the
   two platforms, homepage. Add `checks.package`.
   → verify by `nix build .#paperclip -L`, then check that
   `node -e 'require("sharp")'` runs inside the output's
   `lib/node_modules/@paperclipai/server`.
   Traps: get hashes with `lib.fakeHash` first, then copy the real one from
   the error. Bundled deps (`bundleDependencies`) are already in the
   tarball, so `npm ci` must not fail on them; if it does, use
   `--ignore-scripts` plus `npmRebuildFlags`. If `sharp` fails to load, add
   `autoPatchelfHook` and `vips`/`stdenv.cc.cc.lib` (spec risk). The
   `embedded-postgres` optional binaries may fail patchelf: remove
   `node_modules/@embedded-postgres` in `postInstall` (they are unused).
   Record any of these in this plan if used.

3. `module.nix`: implement exactly the options and behaviour under
   "Approved decisions". Render the config with `(pkgs.formats.json { })
   .generate "paperclip-config.json" cfg.settings`. Start script:
   `pkgs.writeShellScript` that exports the secret if
   `BETTER_AUTH_SECRET` is unset, then `exec ${getExe cfg.package}`. Unit
   `paperclip.service`: `after`/`requires` `postgresql.service` when
   `createLocally`, `Restart = "on-failure"`, `User`/`Group`,
   `StateDirectory = "paperclip"` (if `stateDir` is the default; otherwise
   `systemd.tmpfiles`), `path = cfg.extraPackages`,
   `EnvironmentFile = mkIf (cfg.environmentFile != null)`.
   → verify by evaluating a minimal `nixosSystem` that imports the module
   (done for real in step 4).
   Traps: option types use `lib.types` only, no `str` for enums. `settings`
   uses `type = format.type` (RFC 42). Never interpolate secrets into Nix
   strings.

4. `tests/vm.nix`: `pkgs.testers.runNixOSTest`. One node imports
   `self.nixosModules.paperclip` with `services.paperclip.enable = true`.
   Script: `wait_for_unit("paperclip.service")`, `wait_for_open_port(3100)`,
   `succeed("curl -fsS http://127.0.0.1:3100/api/health")`,
   `succeed("stat -c %a /var/lib/paperclip/auth-secret | grep -x 600")`,
   `fail("journalctl -u paperclip | grep -i 'EROFS\\|read-only file system'")`.
   Add as `checks.vm` (x86_64 only) and `passthru.tests.vm`.
   → verify by `nix build .#checks.x86_64-linux.vm -L`.
   Traps: give the VM `virtualisation.memorySize = 2048`. If startup writes
   to `PAPERCLIP_CONFIG` (EROFS), switch to copying the config into
   `stateDir` in `ExecStartPre` (spec mitigation) and update this plan.

5. `update.sh` (bash, `set -euo pipefail`, shebang `#!/usr/bin/env nix-shell`
   with `-i bash -p nodejs_24 nix-prefetch prefetch-npm-deps gnused jq`):
   `latest=$(npm view @paperclipai/server dist-tags.latest)`; exit 0 if it
   matches `version` in `package.nix`. Otherwise: download the tarball to a
   temp dir, regenerate `package-lock.json` (same npm command), set the new
   `version`, `hash` (`nix hash convert` of `nix-prefetch-url`), and
   `npmDepsHash` (`prefetch-npm-deps package-lock.json`) with `sed`. Print
   the new version for the workflow.
   → verify by `./update.sh` making no diff now.
   Traps: `sed` patterns must each match exactly one line; fail loudly
   (`grep -q` before `sed`) if not.

6. `.github/workflows/ci.yml`, `.github/workflows/update.yml`:
   - `ci.yml`: on push to `main` and on PRs. `actions/checkout@v4`,
     `cachix/install-nix-action@v31` (KVM is on by default on
     ubuntu-latest), then `nix fmt -- --ci` and `nix flake check -L`.
   - `update.yml`: `schedule: cron "0 5 * * *"` and `workflow_dispatch`,
     `permissions: contents: write, pull-requests: write`. Checkout,
     install-nix, run `./update.sh`, then
     `peter-evans/create-pull-request@v7` with branch `update/paperclip`
     and title `paperclip: <old> -> <new>`.
   → verify by `nix run nixpkgs#actionlint`.
   Traps: PRs opened by `GITHUB_TOKEN` do not trigger other workflows. The
   README must say to set a `PAT`/app token secret (`UPDATE_TOKEN`) for CI
   to run on update PRs. The workflow uses
   `token: ${{ secrets.UPDATE_TOKEN || github.token }}`.

7. `README.md`: what it is, flake input usage, a minimal module example,
   an option table (copy from the spec), a `settings`/`environment`
   passthrough example, a secrets example via `environmentFile`, how to add
   agent CLIs through `extraPackages`, the first-admin claim through the UI,
   the update flow and `UPDATE_TOKEN`, and known limits (no runnerd,
   aarch64 untested).
   → verify by reading it.

## Tests

```bash
nix fmt -- --ci                         # no formatting diff
nix flake check -L                      # lint + package + VM test pass
nix build .#paperclip && ls result/bin/paperclip-server
./update.sh && git diff --exit-code     # no change when current
nix run nixpkgs#actionlint              # workflows valid
```

## Rollback

All new files in a new repo. Revert the commits, or drop the branch
`feat/1-nixos-package-module`. Hosts are only affected once they import
the module; removing the import and running `nixos-rebuild switch` undoes it.
The Postgres database `paperclip` and `/var/lib/paperclip` remain and are
deleted by hand.

## Execution

Seven file-editing steps, so per policy the `coder` agent (Sonnet)
implements them one step at a time. A fresh Opus agent reviews the diff
against this plan. The PR (once there is a remote) says which steps the
coder did.
