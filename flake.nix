{
  description = "Cardano Lightning Monorepo";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
    git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    # aiken.url = "github:aiken-lang/aiken/94ff20253b3d43ee5fcf501bb13902f58c729791";
    aiken.url = "git+file:///home/paluh/projects/cardano-lightning/cardano-lightning/aiken?rev=562edc1ccbaed0bbccc2bbeb9370f7aa03259bd6";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;}
    {
      imports = [
        inputs.git-hooks-nix.flakeModule
        inputs.treefmt-nix.flakeModule
      ];
      systems = ["x86_64-linux" "aarch64-darwin"];
      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
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
            alejandra.enable = true;
          };
        };
        pre-commit.settings.hooks = {
          treefmt.enable = true;
          aiken = {
            enable = true;
            name = "aiken";
            description = "Run aiken's formatter on ./aik";
            files = "\\.ak";
            entry = "${inputs'.aiken.packages.aiken}/bin/aiken fmt ./aik";
          };
        };
        # NOTE: You can also use `config.pre-commit.devShell`
        devShells.default = pkgs.mkShell {
          name = "cardano-lightning";
          nativeBuildInputs = [
            config.treefmt.build.wrapper
          ];
          shellHook = ''
            ${config.pre-commit.installationScript}
            echo 1>&2 "Welcome to the development shell!"

            # FIXME: This should be packaged as a tool available in the shell
            export VENV=./aik/test-vectors/.venv
            # create dir if not exists
            if [ ! -d "$VENV" ]; then
              python3 -m venv $VENV
            fi
            source ./$VENV/bin/activate
            pip install -r ./aik/test-vectors/requirements.txt
          '';

          postShellHook = ''
            ln -sf ${pkgs.python311.sitePackages}/* ./.venv/lib/python311.12/site-packages
          '';

          # Let's keep this "path discovery techinque" here for refernece:
          # (builtins.trace (builtins.attrNames inputs.cardano-addresses.packages.${system}) inputs.cardano-cli.packages)
          packages = [
            inputs'.aiken.packages.aiken
            pkgs.python311Packages.frozenlist
            pkgs.python311
            pkgs.nodePackages.mermaid-cli
          ];
        };
      };
      flake = {};
    };
}
