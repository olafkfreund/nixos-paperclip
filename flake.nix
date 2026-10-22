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
        paperclip = (pkgs.callPackage ./package.nix { }).overrideAttrs (_: {
          passthru = {
            tests = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
              inherit (self.checks.x86_64-linux) vm;
            };
          };
        });
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

      checks = forAllSystems (
        pkgs:
        {
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.paperclip;
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
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
          vm = import ./tests/vm.nix { inherit pkgs self; };
        }
      );
    };
}
