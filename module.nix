{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.services.paperclip;
  format = pkgs.formats.json { };
  configFile = format.generate "paperclip-config.json" cfg.settings;
  authSecret = "${cfg.stateDir}/auth-secret";

  # Never put the secret in the store: generate it once in the state dir.
  genSecret = pkgs.writeShellScript "paperclip-gen-secret" ''
    umask 077
    [ -e ${authSecret} ] || ${pkgs.coreutils}/bin/head -c 48 /dev/urandom | ${pkgs.coreutils}/bin/base64 > ${authSecret}
  '';

  start = pkgs.writeShellScript "paperclip-start" ''
    if [ -z "''${BETTER_AUTH_SECRET:-}" ]; then
      BETTER_AUTH_SECRET=$(< ${authSecret})
      export BETTER_AUTH_SECRET
    fi
    exec ${lib.getExe cfg.package}
  '';

  defaultStateDir = cfg.stateDir == "/var/lib/paperclip";
in
{
  options.services.paperclip = {
    enable = mkEnableOption "the Paperclip agent orchestration server";

    package = mkOption {
      type = types.package;
      description = "The Paperclip server package.";
    };

    user = mkOption {
      type = types.str;
      default = "paperclip";
      description = "User account the service runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "paperclip";
      description = "Group the service runs as.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/paperclip";
      description = "Directory for all Paperclip state (config home, logs, storage, secrets).";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on.";
    };

    port = mkOption {
      type = types.port;
      default = 3100;
      description = "TCP port to listen on.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open {option}`port` in the firewall.";
    };

    deploymentMode = mkOption {
      type = types.enum [
        "local_trusted"
        "authenticated"
      ];
      default = "authenticated";
      description = "Paperclip deployment mode.";
    };

    exposure = mkOption {
      type = types.enum [
        "private"
        "public"
      ];
      default = "private";
      description = "Deployment exposure. `public` requires {option}`publicUrl`.";
    };

    publicUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://paperclip.example.com";
      description = "Public base URL, used for auth callbacks.";
    };

    allowedHostnames = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra hostnames the server accepts requests for.";
    };

    database = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Provision a local PostgreSQL database `paperclip` (peer auth over the
          unix socket). Requires {option}`user` to be `paperclip`.
        '';
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          PostgreSQL connection URL when {option}`database.createLocally` is false.
          It ends up in the unit environment; put passwords in {option}`environmentFile` instead.
        '';
      };
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File with `KEY=value` lines for secrets such as `BETTER_AUTH_SECRET`
        or API keys. If it does not set `BETTER_AUTH_SECRET`, one is generated
        in {option}`stateDir`.
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ pkgs.git ];
      defaultText = lib.literalExpression "[ pkgs.git ]";
      description = "Packages on the service `PATH`, e.g. agent CLIs.";
    };

    settings = mkOption {
      inherit (format) type;
      default = { };
      description = ''
        Contents of Paperclip's `config.json`. Typed options above are merged
        in at normal priority; override them with `lib.mkForce`.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables for the service.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.database.createLocally || cfg.database.url != null;
          message = "services.paperclip: set database.url when database.createLocally is false.";
        }
        {
          assertion = cfg.exposure != "public" || cfg.publicUrl != null;
          message = "services.paperclip: exposure = \"public\" requires publicUrl.";
        }
        {
          # ensureDBOwnership needs the database name to equal the role name.
          assertion = !cfg.database.createLocally || cfg.user == "paperclip";
          message = "services.paperclip: database.createLocally requires user = \"paperclip\".";
        }
      ];

      services.paperclip.settings = mkMerge [
        {
          "$meta" = mkDefault {
            version = 1;
            updatedAt = "1970-01-01T00:00:00Z";
            source = "configure";
          };
          database = {
            mode = mkDefault "postgres";
            backup.dir = mkDefault "${cfg.stateDir}/backups";
          };
          updates.checkEnabled = mkDefault false;
          telemetry.enabled = mkDefault false;
          logging = {
            mode = mkDefault "file";
            logDir = mkDefault "${cfg.stateDir}/logs";
          };
          storage.localDisk.baseDir = mkDefault "${cfg.stateDir}/storage";
          secrets.localEncrypted.keyFilePath = mkDefault "${cfg.stateDir}/secrets/master.key";
          server = {
            inherit (cfg)
              host
              port
              deploymentMode
              exposure
              allowedHostnames
              ;
          };
        }
        (mkIf (cfg.publicUrl != null) {
          auth = {
            baseUrlMode = "explicit";
            publicBaseUrl = cfg.publicUrl;
          };
        })
      ];

      users.users.${cfg.user} = {
        isSystemUser = true;
        inherit (cfg) group;
        home = cfg.stateDir;
      };
      users.groups.${cfg.group} = { };

      systemd.tmpfiles.rules = lib.optional (
        !defaultStateDir
      ) "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -";

      networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

      systemd.services.paperclip = {
        description = "Paperclip agent orchestration server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ] ++ lib.optional cfg.database.createLocally "postgresql.service";
        requires = lib.optional cfg.database.createLocally "postgresql.service";
        path = cfg.extraPackages;

        environment = {
          PAPERCLIP_HOME = cfg.stateDir;
          HOME = cfg.stateDir;
          PAPERCLIP_CONFIG = configFile;
          NODE_ENV = "production";
          SERVE_UI = "true";
          DATABASE_URL =
            if cfg.database.createLocally then
              "postgresql:///paperclip?host=/run/postgresql"
            else
              cfg.database.url;
        }
        // cfg.environment;

        serviceConfig = {
          ExecStartPre = genSecret;
          ExecStart = start;
          Restart = "on-failure";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.stateDir;
          StateDirectory = mkIf defaultStateDir "paperclip";
          EnvironmentFile = mkIf (cfg.environmentFile != null) cfg.environmentFile;

          ProtectSystem = "strict";
          ReadWritePaths = [ cfg.stateDir ];
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          SystemCallFilter = [ "@system-service" ];
          # No MemoryDenyWriteExecute: the Node JIT needs W+X pages.
        };
      };
    }

    (mkIf cfg.database.createLocally {
      services.postgresql = {
        enable = true;
        ensureDatabases = [ "paperclip" ];
        ensureUsers = [
          {
            name = cfg.user;
            ensureDBOwnership = true;
          }
        ];
      };
    })
  ]);
}
