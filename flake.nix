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

          opencodeWrapped = pkgs.writeShellScriptBin "opencode-wrapped" ''
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

            CMD="${pkgs.opencode}/bin/opencode"
            if [ "''${1:-}" = "--shell" ]; then
              shift
              CMD="${pkgs.bash}/bin/bash --noprofile --norc"
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
              --bind "$AI_CONFIG_DIR/home/.config" /home/achuie/.config \
              --bind "$AI_CONFIG_DIR/home/.local/share" /home/achuie/.local/share \
              --chdir /workspace \
              --setenv HOME "$HOME" \
              --setenv OPENCODE_CONFIG_DIR "$HOME/.config/opencode" \
              --setenv PATH "${pkgs.lib.makeBinPath (
                [
                  pkgs.opencode
                  pkgs.git
                  pkgs.curl
                  pkgs.jq
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.gnused
                ]
                ++ extraPackages pkgs
              )}" \
              $CMD "$@"
          '';

        in pkgs.mkShell {
          packages = [ opencodeWrapped ];
        };

      devShells = forAllSystems (system: {
        default = self.lib.mkOpenCodeShell { inherit system; };
      });
    };
}
