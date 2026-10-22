# nixos-paperclip

A Nix package and NixOS module for [Paperclip](https://github.com/paperclipai/paperclip),
the agent orchestration server. The package is the `@paperclipai/server` npm tarball
(Node 24); the module runs it as a hardened systemd service.

## Usage

```nix
{
  inputs.paperclip.url = "github:olafkfreund/nixos-paperclip";
  inputs.paperclip.inputs.nixpkgs.follows = "nixpkgs"; # optional

  outputs = { nixpkgs, paperclip, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        paperclip.nixosModules.default
        { services.paperclip.enable = true; }
      ];
    };
  };
}
```

That gives you Paperclip on `127.0.0.1:3100` in `authenticated` mode, with a local
PostgreSQL database `paperclip` reached over the unix socket, and all state in
`/var/lib/paperclip`. `services.paperclip.package` defaults to this flake's package.

Behind a reverse proxy:

```nix
services.paperclip = {
  enable = true;
  exposure = "public";
  publicUrl = "https://paperclip.example.com"; # required for public exposure
  allowedHostnames = [ "paperclip.example.com" ];
};
```

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Run the service. |
| `package` | this flake's package | Server package. |
| `user` / `group` | `paperclip` | Service account. |
| `stateDir` | `/var/lib/paperclip` | All state: logs, storage, backups, secrets. |
| `host` / `port` | `127.0.0.1` / `3100` | Listen address. |
| `openFirewall` | `false` | Open `port`. |
| `deploymentMode` | `authenticated` | `local_trusted` or `authenticated`. |
| `exposure` | `private` | `private` or `public` (needs `publicUrl`). |
| `publicUrl` | `null` | Public base URL for auth callbacks. |
| `allowedHostnames` | `[ ]` | Extra accepted hostnames. |
| `database.createLocally` | `true` | Provision local PostgreSQL (needs `user = "paperclip"`). |
| `database.url` | `null` | Connection URL when not creating locally. |
| `environmentFile` | `null` | `KEY=value` file for secrets. |
| `extraPackages` | `[ pkgs.git ]` | Packages on the service `PATH`. |
| `settings` | `{ }` | Free-form `config.json` contents. |
| `environment` | `{ }` | Extra environment variables. |

### Passthrough: `settings` and `environment`

Typed options are written into `settings` at normal priority, the module's own defaults
(telemetry and update checks off, paths under `stateDir`) at `mkDefault`. Override either:

```nix
services.paperclip = {
  settings.telemetry.enabled = true;          # a module default
  settings.server.port = lib.mkForce 8080;    # a typed option
  environment.TZ = "UTC";
};
```

### Secrets

A `BETTER_AUTH_SECRET` is generated once into `${stateDir}/auth-secret` (mode 600) and
never enters the Nix store. To supply it, or any API key, yourself:

```nix
services.paperclip.environmentFile = "/run/secrets/paperclip.env";
# BETTER_AUTH_SECRET=...
# ANTHROPIC_API_KEY=...
```

### Agent CLIs

Paperclip starts agent CLIs from its `PATH`. None are installed by default:

```nix
services.paperclip.extraPackages = with pkgs; [ git claude-code gemini-cli opencode ];
```

## First admin

A fresh `authenticated` instance has no admin. Open the UI in a browser, sign up and
complete the setup claim: the first authenticated session to claim it wins, so do this
before exposing the instance to anyone else.

## Updates

`./update.sh` looks up `dist-tags.latest` for `@paperclipai/server` on npm and, if newer,
rewrites `version`, `hash`, `npmDepsHash` and `package-lock.json`. The `Update` workflow
runs it daily and opens a PR with `peter-evans/create-pull-request`. PRs created with the
default `GITHUB_TOKEN` do not trigger other workflows, so set a repository secret
`UPDATE_TOKEN` (a PAT or app token) for CI to run on them.

Run the checks locally (formatting, then lint, package build and the NixOS VM test):

```sh
nix fmt -- --ci
nix flake check -L
./update.sh && git diff --exit-code   # no change when already current
```

## Known limits

- `paperclip-runnerd` (the Rust runner daemon) is not packaged.
- The server's `@paperclipai/paperclip-runner/live` ACPX probe cannot be resolved,
  as with upstream npm installs, because that package is vendored but unpublished.
- `aarch64-linux` is built but untested; CI tests `x86_64-linux` only.
- The npm tarball ships no lockfile, so our own `package-lock.json` resolves semver
  ranges at update time rather than reproducing upstream's pins.
- `database.createLocally` requires `user = "paperclip"` (database name must equal the
  role name for `ensureDBOwnership`).
- Disabling the module does not remove the PostgreSQL database `paperclip` or
  `/var/lib/paperclip`; delete them by hand.
