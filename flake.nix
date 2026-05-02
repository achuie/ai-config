{
  description = "Minimal bwrap-wrapped opencode with relocatable HOME";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

    in {
      lib.mkOpenCodeShell =
        { system
        , extraPackages ? (_: [])
        }:
        let
          pkgs = import nixpkgs { inherit system; };

          opencodeWrapped = pkgs.writeShellScriptBin "opencode" ''
            set -euo pipefail

            if [ -z "''${AI_CONFIG_DIR:-}" ]; then
              echo "AI_CONFIG_DIR not set" >&2
              exit 1
            fi

            HOME="$AI_CONFIG_DIR/home"
            export HOME

            mkdir -p \
              "$HOME/.config/opencode" \
              "$HOME/.local/share/opencode" \
              "$HOME/.cache/opencode"

            if [ "''${1:-}" = "--shell" ]; then
              shift
              exec ${pkgs.bash}/bin/bash "$@"
            fi

            exec ${pkgs.bubblewrap}/bin/bwrap \
              --unshare-all \
              --share-net \
              --die-with-parent \
              --proc /proc \
              --dev /dev \
              --ro-bind /nix/store /nix/store \
              --ro-bind /etc/resolv.conf /etc/resolv.conf \
              --ro-bind-try /etc/ssl/certs /etc/ssl/certs \
              --tmpfs /tmp \
              --setenv TMPDIR /tmp \
              --dev-bind /dev/shm /dev/shm \
              --bind "$HOME" "$HOME" \
              --bind "$(pwd -P)" /workspace \
              --chdir /workspace \
              --setenv HOME "$HOME" \
              --setenv PATH "${pkgs.lib.makeBinPath (
                [ pkgs.opencode pkgs.git pkgs.curl pkgs.jq ]
                ++ extraPackages pkgs
              )}" \
              ${pkgs.opencode}/bin/opencode "$@"
          '';

        in pkgs.mkShell {
          packages = [ opencodeWrapped ];
        };

      devShells = forAllSystems (system: {
        default = self.lib.mkOpenCodeShell { inherit system; };
      });
    };
}
