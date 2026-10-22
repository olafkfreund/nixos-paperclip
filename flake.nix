{
  description = "Paperclip (agent orchestration server) packaged for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        paperclip = pkgs.callPackage ./package.nix { };
        default = paperclip;
      });

      nixosModules = rec {
        paperclip =
          { lib, pkgs, ... }:
          {
            imports = [ ./module.nix ];
            services.paperclip.package =
              lib.mkDefault
                self.packages.${pkgs.stdenv.hostPlatform.system}.paperclip;
          };
        default = paperclip;
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      checks = forAllSystems (pkgs: {
        lint =
          pkgs.runCommand "lint"
            {
              nativeBuildInputs = [
                pkgs.statix
                pkgs.deadnix
              ];
            }
            ''
              cd ${self}
              statix check .
              deadnix --fail .
              touch $out
            '';
      });
    };
}
