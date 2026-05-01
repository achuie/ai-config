{
  description = "opencode AI assistant with persistent cross-project state";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-sandbox = {
      url = "github:archie-judd/agent-sandbox.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, agent-sandbox, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      # -----------------------------------------------------------------------
      # lib.mkOpenCodeShell
      #
      # Returns a devShell with a sandboxed `opencode` binary.  Import this
      # flake as an input in any project flake and call:
      #
      #   ai-config.lib.mkOpenCodeShell {
      #     system = "x86_64-linux";
      #     extraPackages = pkgs: [ pkgs.nodejs pkgs.rustc ];
      #   };
      #
      # Before entering the shell, export:
      #   export AI_CONFIG_DIR=/path/to/this/ai-config/repo
      #   export OPENCODE_API_KEY=<your key>  # optional if auth.json is used
      # -----------------------------------------------------------------------
      lib.mkOpenCodeShell = { system, extraPackages ? (_: []) }:
        let
          pkgs = import nixpkgs { inherit system; };
          sandbox = agent-sandbox.lib.${system};

          # The core sandboxed binary.  stateDirs use shell variable references
          # so they are expanded at runtime (after the outer wrapper has
          # validated $AI_CONFIG_DIR).
          opencode-sandboxed = sandbox.mkSandbox {
            pkg = pkgs.opencode;
            binName = "opencode";
            outName = "opencode-sandboxed";

            allowedPackages = [
              pkgs.coreutils
              pkgs.git
              pkgs.ripgrep
              pkgs.fd
              pkgs.gnused
              pkgs.gnugrep
              pkgs.findutils
              pkgs.diffutils
              pkgs.less
              pkgs.gawk
              pkgs.jq
              pkgs.which
              pkgs.curl
              pkgs.xdg-utils
            ] ++ extraPackages pkgs;

            # All paths are rooted at $AI_CONFIG_DIR and shell-expanded at
            # runtime by the sandbox wrapper script.
            stateDirs = [
              "$AI_CONFIG_DIR/data/home/.local/share/opencode"
              "$AI_CONFIG_DIR/data/home/.local/state/opencode"
              "$AI_CONFIG_DIR/data/home/.cache/opencode"
              "$AI_CONFIG_DIR/data/home/.config/opencode"
            ];

            extraEnv = {
              # Config dir: points at the config/ directory in this repo.
              OPENCODE_CONFIG_DIR = "$AI_CONFIG_DIR/config";

              # API key: read from host environment at runtime, never stored
              # in the Nix store.
              OPENCODE_API_KEY = "$OPENCODE_API_KEY";

              # Pass through git identity so opencode-initiated commits are
              # attributed correctly.
              GIT_AUTHOR_NAME     = "$GIT_AUTHOR_NAME";
              GIT_AUTHOR_EMAIL    = "$GIT_AUTHOR_EMAIL";
              GIT_COMMITTER_NAME  = "$GIT_COMMITTER_NAME";
              GIT_COMMITTER_EMAIL = "$GIT_COMMITTER_EMAIL";
            };
          };

          # Outer wrapper: validates $AI_CONFIG_DIR, pre-creates state
          # directories (so the sandbox bwrap --bind calls succeed), then
          # hands off to the sandboxed binary which inherits the env.
          opencode-wrapper = pkgs.writeShellScriptBin "opencode-wrapped" ''
            set -euo pipefail

            if [ -z "''${AI_CONFIG_DIR:-}" ]; then
              echo "error: AI_CONFIG_DIR is not set." >&2
              echo "       Export the path to your ai-config repo before running opencode." >&2
              echo "       e.g.  export AI_CONFIG_DIR=~/projects/ai-config" >&2
              exit 1
            fi

            if [ ! -d "$AI_CONFIG_DIR" ]; then
              echo "error: AI_CONFIG_DIR does not point to an existing directory: $AI_CONFIG_DIR" >&2
              exit 1
            fi

            # Pre-create state dirs so bwrap --bind succeeds even on a fresh checkout.
            mkdir -p \
              "$AI_CONFIG_DIR/data/home/.local/share/opencode" \
              "$AI_CONFIG_DIR/data/home/.local/state/opencode" \
              "$AI_CONFIG_DIR/data/home/.cache/opencode" \
              "$AI_CONFIG_DIR/data/home/.config/opencode"

            exec ${opencode-sandboxed}/bin/opencode-sandboxed "$@"
          '';

        in pkgs.mkShell {
          packages = [ opencode-wrapper ];
        };

      # Default devShell for this repo itself (no project-specific packages).
      devShells = forAllSystems (system: {
        default = self.lib.mkOpenCodeShell { inherit system; };
      });
    };
}
