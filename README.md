# nixos-paperclip

[![CI](https://github.com/olafkfreund/nixos-paperclip/actions/workflows/ci.yml/badge.svg)](https://github.com/olafkfreund/nixos-paperclip/actions/workflows/ci.yml)
[![Update](https://github.com/olafkfreund/nixos-paperclip/actions/workflows/update.yml/badge.svg)](https://github.com/olafkfreund/nixos-paperclip/actions/workflows/update.yml)

This repo is a Nix package and NixOS module for
[Paperclip](https://github.com/paperclipai/paperclip), the open-source agent
orchestration server with a web UI. It runs Paperclip as a hardened systemd
service backed by NixOS's own PostgreSQL. All configuration is declarative, and
each Paperclip version is pinned and tested in CI.

- **Package:** `packages.<system>.paperclip`, upstream's published
  `@paperclipai/server` npm release (server and web UI), on Node.js 24.
- **Module:** `nixosModules.default`, which provides `services.paperclip`.
- **Systems:** `x86_64-linux` is tested in CI. `aarch64-linux` builds but is
  untested.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Verify the installation](#verify-the-installation)
- [First login](#first-login)
- [Configuration examples](#configuration-examples)
- [Option reference](#option-reference)
- [Upgrades, rollback and removal](#upgrades-rollback-and-removal)
- [How this repo is built and tested](#how-this-repo-is-built-and-tested)
- [Automatic nightly updates](#automatic-nightly-updates)
- [Developing locally](#developing-locally)
- [Known limits](#known-limits)

## Requirements

- NixOS with flakes enabled:
  `nix.settings.experimental-features = [ "nix-command" "flakes" ];`
- About 1.5 GB of disk for the package closure, and 1 GB of RAM or more for the
  service.
- Agents need API keys for the providers you plan to use, such as
  `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. See [Secrets](#secrets-and-api-keys).

## Install

### With flakes (recommended)

Add the input and the module to your system flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    paperclip = {
      url = "github:olafkfreund/nixos-paperclip";
      inputs.nixpkgs.follows = "nixpkgs"; # optional: share your nixpkgs
    };
  };

  outputs = { nixpkgs, paperclip, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        paperclip.nixosModules.default
        { services.paperclip.enable = true; }
      ];
    };
  };
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch --flake .#myhost
```

This configuration gives you:

- Paperclip listening on `127.0.0.1:3100` in `authenticated` mode, with
  login required.
- A local PostgreSQL database `paperclip`, reached over the unix socket with
  peer auth. No password is needed.
- All state under `/var/lib/paperclip` (mode 0750), owned by the `paperclip`
  system user.
- A generated auth secret in `/var/lib/paperclip/auth-secret` (mode 0600). It
  never enters the Nix store.

`services.paperclip.package` defaults to this flake's package, so the version
you get is whatever the `paperclip` input is locked to.

> [!NOTE]
> With `inputs.nixpkgs.follows`, the package builds against your nixpkgs
> instead of the one CI tested. Leave `follows` out if you want the exact
> combination CI verified.

### Without flakes

```nix
{ pkgs, ... }:
let
  src = builtins.fetchTarball "https://github.com/olafkfreund/nixos-paperclip/archive/main.tar.gz";
in
{
  imports = [ "${src}/module.nix" ];
  services.paperclip = {
    enable = true;
    package = pkgs.callPackage "${src}/package.nix" { };
  };
}
```

### Try the server without installing

Run it as your own user. Without `DATABASE_URL` it falls back to upstream's
embedded PostgreSQL in `~/.paperclip`:

```bash
nix run github:olafkfreund/nixos-paperclip
```

## Verify the installation

After `nixos-rebuild switch`:

```bash
systemctl status paperclip.service          # active (running)
curl -fsS http://127.0.0.1:3100/api/health  # health JSON, HTTP 200
journalctl -u paperclip -f                  # logs; first start runs ~300 DB migrations
sudo -u postgres psql -c '\l paperclip'     # database exists, owned by paperclip
```

The first start takes 10 to 30 seconds while the migrations run. After that,
restarts are quick.

## First login

A new `authenticated` instance has no admin. Open the UI in a browser
(`http://127.0.0.1:3100`, or your `publicUrl`), sign up, and complete the setup
claim. The first signed-in session to claim the instance becomes admin, so do
this before anyone else can reach it. To close sign-ups afterwards:

```nix
services.paperclip.settings.auth.disableSignUp = true;
```

## Configuration examples

### Single user on a workstation (no login)

```nix
services.paperclip = {
  enable = true;
  deploymentMode = "local_trusted"; # no login; only safe on 127.0.0.1
};
```

### LAN access without a proxy

```nix
services.paperclip = {
  enable = true;
  host = "0.0.0.0";
  openFirewall = true;                      # opens port 3100
  allowedHostnames = [ "paperclip.lan" "192.168.1.20" ];
};
```

### Public, behind nginx with TLS (recommended for remote access)

```nix
services.paperclip = {
  enable = true;
  exposure = "public";
  publicUrl = "https://paperclip.example.com"; # required when exposure = "public"
  allowedHostnames = [ "paperclip.example.com" ];
  settings.auth.disableSignUp = true;           # after you have claimed admin
};

services.nginx = {
  enable = true;
  recommendedProxySettings = true;
  recommendedTlsSettings = true;
  virtualHosts."paperclip.example.com" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:3100";
      proxyWebsockets = true; # live events and terminals use websockets
    };
  };
};

security.acme = {
  acceptTerms = true;
  defaults.email = "you@example.com";
};
networking.firewall.allowedTCPPorts = [ 80 443 ];
```

### Secrets and API keys

Secrets go in an `environmentFile`, one `KEY=value` per line, readable by root
only. systemd reads the file at start, so its contents never reach the Nix
store.

```nix
services.paperclip.environmentFile = "/run/secrets/paperclip.env";
```

```bash
# /run/secrets/paperclip.env
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
# Optional: pin the auth secret yourself instead of the generated one.
BETTER_AUTH_SECRET=...
```

With [sops-nix](https://github.com/Mic92/sops-nix):

```nix
sops.secrets."paperclip.env" = { };
services.paperclip.environmentFile = config.sops.secrets."paperclip.env".path;
```

With [agenix](https://github.com/ryantm/agenix):

```nix
age.secrets.paperclip-env.file = ./secrets/paperclip.env.age;
services.paperclip.environmentFile = config.age.secrets.paperclip-env.path;
```

### Agent CLIs

Paperclip's adapters start agent CLIs from the service's `PATH`. Only `git` is
installed by default. Add the CLIs you use from nixpkgs:

```nix
services.paperclip.extraPackages = with pkgs; [
  git
  claude-code   # Claude Code adapter
  codex         # Codex adapter
  gemini-cli    # Gemini adapter
  opencode      # OpenCode adapter
];
nixpkgs.config.allowUnfree = true; # claude-code is unfree
```

### External PostgreSQL

```nix
services.paperclip = {
  enable = true;
  database.createLocally = false;
  # Keep the password out of the store: put DATABASE_URL in the environment file.
  environmentFile = "/run/secrets/paperclip.env";
};
```

```bash
# /run/secrets/paperclip.env
DATABASE_URL=postgres://paperclip:PASSWORD@db.example.com:5432/paperclip
```

If the URL holds no password, you can set it in Nix instead:
`database.url = "postgres://paperclip@db.example.com/paperclip";`.

### S3-compatible storage for attachments

```nix
services.paperclip.settings.storage = {
  provider = "s3";
  s3 = {
    bucket = "paperclip";
    region = "eu-west-1";
    endpoint = "https://s3.example.com"; # leave out for AWS
    forcePathStyle = true;                # MinIO and most self-hosted S3
  };
};
# Credentials: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in environmentFile.
```

### Database backups (upstream's built-in backup job)

```nix
services.paperclip.settings.database.backup = {
  enabled = true;
  intervalMinutes = 360;
  retentionDays = 14;
  # dir defaults to /var/lib/paperclip/backups
};
```

### Any other upstream setting

The typed options cover what NixOS needs to know. Everything else in
Paperclip's `config.json` goes through `settings`, and any environment variable
goes through `environment`. See upstream's
[config schema](https://github.com/paperclipai/paperclip/blob/master/packages/shared/src/config-schema.ts).
Typed options are set at normal priority and module defaults at `mkDefault`,
so you can override either:

```nix
services.paperclip = {
  settings.telemetry.enabled = true;          # module default is false
  settings.updates.checkEnabled = false;      # Nix manages versions
  settings.server.port = lib.mkForce 8080;    # overrides the typed `port`
  environment.TZ = "Europe/London";
};
```

To see the generated config:

```bash
cat "$(systemctl show -p Environment paperclip | grep -o 'PAPERCLIP_CONFIG=[^ ]*' | cut -d= -f2)"
```

## Option reference

All options sit under `services.paperclip`.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Run the service. |
| `package` | package | this flake's package | Server package. |
| `user` / `group` | str | `paperclip` | Service account. Must stay `paperclip` when `database.createLocally`. |
| `stateDir` | path | `/var/lib/paperclip` | All state: logs, storage, backups, secrets. |
| `host` | str | `127.0.0.1` | Listen address. |
| `port` | port | `3100` | Listen port. |
| `openFirewall` | bool | `false` | Open `port` in the firewall. |
| `deploymentMode` | `local_trusted` \| `authenticated` | `authenticated` | Login required or not. |
| `exposure` | `private` \| `public` | `private` | `public` requires `publicUrl`. |
| `publicUrl` | null or str | `null` | Public base URL for auth callbacks. Sets `auth.baseUrlMode = "explicit"`. |
| `allowedHostnames` | list of str | `[ ]` | Hostnames the server accepts requests for. |
| `database.createLocally` | bool | `true` | Provision local PostgreSQL with peer auth. |
| `database.url` | null or str | `null` | `DATABASE_URL` when not local. Use `environmentFile` if it holds a password. |
| `environmentFile` | null or path | `null` | `KEY=value` file for secrets and extra env. |
| `extraPackages` | list of package | `[ pkgs.git ]` | Packages on the service `PATH`, such as agent CLIs. |
| `settings` | JSON | `{ }` | Free-form Paperclip `config.json`. |
| `environment` | attrs of str | `{ }` | Extra environment variables. |

The service runs as `paperclip` under `ProtectSystem=strict`, `ProtectHome`,
`PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, `UMask=0077`, the
`@system-service` syscall filter and restricted address families. Agents can
only write to `stateDir`.

## Upgrades, rollback and removal

- **Upgrade:** `nix flake update paperclip`, then `nixos-rebuild switch`.
  Database migrations run on the next start.
- **Pin a version:** lock the input to a commit or tag, for example
  `github:olafkfreund/nixos-paperclip/<commit>`.
- **Roll back:** `nixos-rebuild switch --rollback`. Migrations are forward-only,
  so restore a backup from `/var/lib/paperclip/backups` if the older version
  rejects the newer schema.
- **Remove:** drop the module and rebuild. The database and state are kept on
  purpose. Delete them by hand:

  ```bash
  sudo -u postgres dropdb paperclip && sudo -u postgres dropuser paperclip
  sudo rm -rf /var/lib/paperclip
  ```

## How this repo is built and tested

```mermaid
flowchart LR
  A[push / PR / nightly 04:00 UTC] --> B[CI workflow]
  B --> C[nix fmt --ci]
  C --> D[nix flake check]
  D --> E[lint: statix, deadnix, shellcheck]
  D --> F[package build]
  D --> G[NixOS VM test]
```

The **CI** workflow (`.github/workflows/ci.yml`) runs on every push to `main`,
on every pull request, every night at 04:00 UTC, and on manual dispatch. The
nightly run catches breakage that arrives without a commit here, for example
from GitHub's runner image or from npm. It runs these steps:

1. **KVM access:** a udev rule makes `/dev/kvm` usable, so the VM test runs
   with hardware virtualisation.
2. **Formatting:** `nix fmt -- --ci` fails if any `.nix` file is not
   nixfmt-formatted.
3. **`nix flake check -L`**, which builds every check:
   - `lint`: `statix check`, `deadnix --fail` and `shellcheck` on `update.sh`.
   - `package`: the full Paperclip build. It fetches the npm release by hash,
     installs the dependencies from our pinned `package-lock.json`
     (`npmDepsHash`), and wraps the server with Node 24.
   - `vm` (`tests/vm.nix`): boots a NixOS VM with
     `services.paperclip.enable = true` and local PostgreSQL, then asserts
     that:
     - the unit starts and port 3100 opens;
     - `GET /api/health` returns HTTP 200;
     - `auth-secret` has mode 600 and `/var/lib/paperclip` has mode 750;
     - the journal has no read-only filesystem errors.

A green CI run means the exact pinned version installs, starts, migrates its
database and serves requests on NixOS.

## Automatic nightly updates

```mermaid
flowchart LR
  A[nightly 05:00 UTC] --> B[update.sh: npm latest?]
  B -- same version --> C[exit: nothing to do]
  B -- new version --> D[bump version, hash, lockfile, npmDepsHash]
  D --> E[nix flake check: build + lint + VM test]
  E -- fails --> F[run fails, no PR]
  E -- passes --> G[open PR update/paperclip]
```

The **Update** workflow (`.github/workflows/update.yml`) runs every night at
05:00 UTC, and on demand from the Actions tab (*Update → Run workflow*):

1. `update.sh` reads `dist-tags.latest` of `@paperclipai/server` from npm. It
   only takes stable releases, never canaries. If that matches `version` in
   `package.nix`, the run ends with nothing to do.
2. If there is a new version, the script:
   - downloads the tarball and computes its SRI `hash`;
   - regenerates `package-lock.json`, because the npm release ships no
     lockfile;
   - computes `npmDepsHash`;
   - rewrites `package.nix`.

   Every edit is checked before it is applied, so a failed run leaves the
   files unchanged.
3. The workflow then runs `nix flake check -L` on the bumped tree: the same
   build, lint and VM test as CI. A version that doesn't build or boot fails
   the run, and you get GitHub's failed-workflow email instead of a broken PR.
4. Only after that passes does it open or refresh a PR on the branch
   `update/paperclip`, titled `paperclip: <old> -> <new>`. Merge the PR to ship
   the update. Consumers pick it up with `nix flake update paperclip`.

Repository settings this needs. Both are already set on this repo; forks
must set them:

- *Settings → Actions → General → Workflow permissions*: **Read and write**,
  with **Allow GitHub Actions to create and approve pull requests** enabled.
- Optional: a repository secret `UPDATE_TOKEN` holding a fine-grained PAT or
  GitHub App token with *contents* and *pull-requests* write. PRs opened with
  the default `GITHUB_TOKEN` don't trigger other workflows. With
  `UPDATE_TOKEN`, CI also runs on the update PR, which gives a status check
  for branch protection. Without it, the verification in step 3 is the gate.

> [!NOTE]
> The update job bumps Paperclip only. `flake.lock` (nixpkgs) is updated by
> hand with `nix flake update nixpkgs`, followed by a PR, so CI can verify it.

## Developing locally

```bash
nix fmt                                  # format
nix fmt -- --ci                          # check formatting, as CI does
nix flake check -L                       # lint + package + VM test (needs KVM)
nix build .#paperclip && ls result/bin   # just the package
nix build .#checks.x86_64-linux.vm -L    # just the VM test
./update.sh                              # bump to the latest npm release, if any
nix run nixpkgs#actionlint               # lint the workflows
```

The repo follows an intent, spec, then plan workflow. The design decisions,
the alternatives considered and the rejected ones are in `intent/`, `spec/`
and `plan/`.

## Known limits

- `paperclip-runnerd`, upstream's Rust runner daemon, is not packaged. The
  server runs without it. The `@paperclipai/paperclip-runner/live` ACPX probe
  cannot resolve, just as with upstream's own npm install.
- The npm release ships no lockfile. Our `package-lock.json` resolves semver
  ranges on the day of the update, so transitive versions can differ from the
  ones upstream tested. The VM test catches startup failures, not feature
  regressions.
- Upstream's embedded PostgreSQL is not used by the module. It works with
  `nix run`.
- `aarch64-linux` builds but is not tested in CI.

## License

The packaging in this repo is MIT. Paperclip itself is MIT ©
[Paperclip AI](https://github.com/paperclipai/paperclip).
