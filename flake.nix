{
  description = "Cardano Lightning Network blog";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pre-commit-hooks-nix.url = "github:hercules-ci/pre-commit-hooks.nix/flakeModule";
    pre-commit-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    cardano-addresses.url = "github:IntersectMBO/cardano-addresses";
    cardano-cli.url = "github:IntersectMBO/cardano-cli";
    bech32.url = "github:IntersectMBO/bech32";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; }
      {
        imports = [
          inputs.pre-commit-hooks-nix.flakeModule
          inputs.treefmt-nix.flakeModule
        ];
        systems = [ "x86_64-linux" "aarch64-darwin" ];
        perSystem = { config, self', inputs', pkgs, system, ... }: {
          treefmt = {
            projectRootFile = "flake.nix";
            flakeFormatter = true;
            programs = {
              prettier = {
                enable = true;
                settings = {
                  printWidth = 80;
                  proseWrap = "always";
                };
              };
            };
          };

          devShells.default =
          pkgs.mkShell {
            nativeBuildInputs = [
              config.treefmt.build.wrapper
            ]
            ;
            shellHook = ''
              echo 1>&2 "Welcome to the development shell!"
            '';
            name = "cardano-lightning";
            # Let's keep this "path discovery techinque" here for refernece:
            # (builtins.trace (builtins.attrNames inputs.cardano-addresses.packages.${system}) inputs.cardano-cli.packages)
            packages = with pkgs; [
              inputs.cardano-cli.packages.${system}."cardano-cli:exe:cardano-cli"
              inputs.cardano-addresses.packages.${system}."cardano-addresses-cli:exe:cardano-address"
              inputs.bech32.packages.${system}."bech32:exe:bech32"
              b2sum
            ];
          };
        };
        flake = { };
      };
}
