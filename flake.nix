{
  description = "Cardano Lightning Network blog";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
    git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; }
      {
        imports = [
          inputs.git-hooks-nix.flakeModule
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
          pre-commit.settings.hooks.treefmt.enable = true;
          # NOTE: You can also use `config.pre-commit.devShell`
          devShells.default =
          pkgs.mkShell {
            nativeBuildInputs = [
              config.treefmt.build.wrapper
            ]
            ;
            shellHook = ''
              ${config.pre-commit.installationScript}
              echo 1>&2 "Welcome to the development shell!"
            '';
            name = "cardano-lightning";
            # Let's keep this "path discovery techinque" here for refernece:
            # (builtins.trace (builtins.attrNames inputs.cardano-addresses.packages.${system}) inputs.cardano-cli.packages)
            packages = with pkgs; [
            ];
          };
        };
        flake = { };
      };
}
