{
  description = "Minimal sandbox-wrapped opencode with relocatable HOME";

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
      lib = rec {
        mkOpenCodePackage =
        { system
        , extraPackages ? (_: [])
        }:
        let
          pkgs = import nixpkgs { inherit system; };

          binPath = pkgs.lib.makeBinPath (
            [
              pkgs.opencode
              pkgs.git
              pkgs.curl
              pkgs.jq
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.nix
            ]
            ++ extraPackages pkgs
          );

          # Shared bash preamble: state root resolution, HOME redirect, dir creation.
          commonPrologue = ''
            set -euo pipefail

            # Capture real home before redirecting HOME (used for defaults and on macOS).
            REAL_HOME="$HOME"

            if [ -z "''${AI_CONFIG_DIR:-}" ]; then
              if [ -n "''${XDG_DATA_HOME:-}" ]; then
                AI_CONFIG_DIR="$XDG_DATA_HOME/ai-config"
              else
                AI_CONFIG_DIR="$REAL_HOME/.local/share/ai-config"
              fi
            fi

            mkdir -p "$AI_CONFIG_DIR"

            if ! CONFIG_ROOT="$(cd "$AI_CONFIG_DIR" 2>/dev/null && pwd -P)"; then
              echo "AI_CONFIG_DIR does not exist: $AI_CONFIG_DIR" >&2
              exit 1
            fi

            AI_CONFIG_DIR="$CONFIG_ROOT"
            export AI_CONFIG_DIR

            HOME="$AI_CONFIG_DIR/home"
            export HOME

            XDG_CONFIG_HOME="$HOME/.config"
            XDG_DATA_HOME="$HOME/.local/share"
            XDG_STATE_HOME="$HOME/.local/state"
            XDG_CACHE_HOME="$HOME/.cache"
            export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

            OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
            export OPENCODE_CONFIG_DIR

            mkdir -p \
              "$XDG_CONFIG_HOME/opencode" \
              "$XDG_DATA_HOME/opencode" \
              "$XDG_STATE_HOME/opencode" \
              "$XDG_CACHE_HOME/opencode"

            NIX_CONFIG="''${NIX_CONFIG:-experimental-features = nix-command flakes}"
            NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt}"
            SSL_CERT_FILE="''${SSL_CERT_FILE:-$NIX_SSL_CERT_FILE}"
            export NIX_CONFIG NIX_SSL_CERT_FILE SSL_CERT_FILE

            WORKSPACE_HOST="$(pwd -P)"

            if [ "''${1:-}" = "--where" ]; then
              printf '%s\n' \
                "AI_CONFIG_DIR=$AI_CONFIG_DIR" \
                "HOME=$HOME" \
                "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" \
                "XDG_DATA_HOME=$XDG_DATA_HOME" \
                "XDG_STATE_HOME=$XDG_STATE_HOME" \
                "XDG_CACHE_HOME=$XDG_CACHE_HOME" \
                "OPENCODE_CONFIG_DIR=$OPENCODE_CONFIG_DIR" \
                "OPENCODE_DATA_DIR=$XDG_DATA_HOME/opencode" \
                "WORKSPACE_HOST=$WORKSPACE_HOST" \
                "WORKSPACE_SANDBOX=/workspace"
              exit 0
            fi
          '';

          # Shared --shell / CMD dispatch.
          cmdDispatch = ''
            if [ "''${1:-}" = "--shell" ]; then
              shift
              CMD=(${pkgs.bash}/bin/bash --noprofile --norc)
            else
              CMD=(${pkgs.opencode}/bin/opencode)
            fi
          '';

          opencodeWrapped =
            if pkgs.stdenv.isLinux then
              # Linux: full namespace isolation via bubblewrap
              pkgs.writeShellScriptBin "opencode-wrapped"
                (commonPrologue + ''
                  # Discover runtime identity for synthetic /etc files.
                  _UID=$(id -u)
                  _GID=$(id -g)
                  _USERNAME=$(id -un)
                  _GROUPNAME=$(id -gn)

                  # Synthetic /etc/passwd — home dir points at the sandbox HOME so
                  # that getpwuid_r() (used by Node's os.homedir(), Go's user.Current(),
                  # etc.) agrees with $HOME rather than returning the real host home.
                  _PASSWD=$(printf '%s\n%s\n' \
                    "$_USERNAME:x:$_UID:$_GID:$_USERNAME:$HOME:${pkgs.bash}/bin/bash" \
                    "nobody:x:65534:65534:Nobody:/:/dev/null")

                  # Synthetic /etc/group
                  _GROUP=$(printf '%s\n%s\n' \
                    "$_GROUPNAME:x:$_GID:$_USERNAME" \
                    "nogroup:x:65534:")

                  # Synthetic /etc/nsswitch.conf — files only; prevents libc from
                  # trying LDAP/NIS modules that don't exist in the sandbox.
                  _NSSWITCH=$(printf '%s\n%s\n%s\n' \
                    "passwd:   files" \
                    "group:    files" \
                    "hosts:    files dns")

                '' + cmdDispatch + ''
                  # FDs 3/4/5 are opened as herestrings below and consumed by
                  # bwrap's --file before the child process is spawned.
                  exec ${pkgs.bubblewrap}/bin/bwrap \
                    --unshare-all \
                    --share-net \
                    --die-with-parent \
                    --proc /proc \
                    --dev /dev \
                    --bind /nix/store /nix/store \
                    --dir /nix/var \
                    --dir /nix/var/nix \
                    --ro-bind-try /etc/nix /etc/nix \
                    --bind-try /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket \
                    --ro-bind-try /nix/var/nix/profiles /nix/var/nix/profiles \
                    --ro-bind /etc/resolv.conf /etc/resolv.conf \
                    --ro-bind /etc/hosts /etc/hosts \
                    --ro-bind-try /etc/ssl/certs /etc/ssl/certs \
                    --ro-bind-try /etc/pki/tls/certs /etc/pki/tls/certs \
                    --file 3 /etc/passwd \
                    --file 4 /etc/group \
                    --file 5 /etc/nsswitch.conf \
                    --tmpfs /tmp \
                    --setenv TMPDIR /tmp \
                    --bind-try /dev/shm /dev/shm \
                    --bind "$HOME" "$HOME" \
                    --bind "$WORKSPACE_HOST" /workspace \
                    --dir /home \
                    --dir "/home/$_USERNAME" \
                    --dir "/home/$_USERNAME/.local" \
                    --bind "$XDG_CONFIG_HOME" "/home/$_USERNAME/.config" \
                    --bind "$XDG_DATA_HOME" "/home/$_USERNAME/.local/share" \
                    --bind "$XDG_STATE_HOME" "/home/$_USERNAME/.local/state" \
                    --bind "$XDG_CACHE_HOME" "/home/$_USERNAME/.cache" \
                    --dir /bin \
                    --dir /usr/bin \
                    --symlink ${pkgs.bash}/bin/bash /bin/sh \
                    --symlink ${pkgs.coreutils}/bin/env /usr/bin/env \
                    --chdir /workspace \
                    --setenv HOME "$HOME" \
                    --setenv USER "$_USERNAME" \
                    --setenv LOGNAME "$_USERNAME" \
                    --setenv XDG_CONFIG_HOME "$XDG_CONFIG_HOME" \
                    --setenv XDG_DATA_HOME "$XDG_DATA_HOME" \
                    --setenv XDG_STATE_HOME "$XDG_STATE_HOME" \
                    --setenv XDG_CACHE_HOME "$XDG_CACHE_HOME" \
                    --setenv OPENCODE_CONFIG_DIR "$OPENCODE_CONFIG_DIR" \
                    --setenv NIX_CONFIG "$NIX_CONFIG" \
                    --setenv NIX_SSL_CERT_FILE "$NIX_SSL_CERT_FILE" \
                    --setenv SSL_CERT_FILE "$SSL_CERT_FILE" \
                    --setenv PATH "${binPath}" \
                    "''${CMD[@]}" "$@" \
                    3<<<"$_PASSWD" \
                    4<<<"$_GROUP" \
                    5<<<"$_NSSWITCH"
                '')
            else
              # macOS: filesystem access control via Seatbelt (sandbox-exec).
              # Note: sandbox-exec is deprecated as of macOS 10.15 but remains
              # functional. It does not provide namespace isolation; instead it
              # enforces a MAC policy. The profile below allows everything by
              # default and then carves out denials + targeted re-allows so that:
              #   - The real home is completely inaccessible (read + write).
              #   - The sandbox home ($AI_CONFIG_DIR/home) is read/write.
              #   - The workspace is read/write.
              # Rule evaluation: last matching rule wins, so the re-allows for
              # HOME_DIR and WORKSPACE (listed after) override the deny on REAL_HOME.
              pkgs.writeShellScriptBin "opencode-wrapped"
                (commonPrologue + ''
                  # sandbox-exec inherits the parent environment (no --setenv needed).
                  export PATH="${binPath}"
                  export USER="$(id -un)"
                  export LOGNAME="$USER"
                  export TMPDIR="''${TMPDIR:-/tmp}"

                '' + cmdDispatch + ''
                  exec /usr/bin/sandbox-exec \
                    -D REAL_HOME="$REAL_HOME" \
                    -D HOME_DIR="$HOME" \
                    -D WORKSPACE="$WORKSPACE_HOST" \
                    -p '
                      (version 1)
                      (allow default)
                      (deny file-read* file-write*
                        (subpath (param "REAL_HOME")))
                      (allow file-read* file-write*
                        (subpath (param "HOME_DIR")))
                      (allow file-read* file-write*
                        (subpath (param "WORKSPACE")))
                    ' \
                    -- "''${CMD[@]}" "$@"
                '');

        in opencodeWrapped;

        mkOpenCodeShell =
        { system
        , extraPackages ? (_: [])
        }:
        let
          pkgs = import nixpkgs { inherit system; };
        in pkgs.mkShell {
          packages = [ (mkOpenCodePackage { inherit system extraPackages; }) ];
        };
      };

      packages = forAllSystems (system: {
        opencode-wrapped = self.lib.mkOpenCodePackage { inherit system; };
        default = self.packages.${system}.opencode-wrapped;
      });

      apps = forAllSystems (system: {
        opencode-wrapped = {
          type = "app";
          program = "${self.packages.${system}.opencode-wrapped}/bin/opencode-wrapped";
        };
        default = self.apps.${system}.opencode-wrapped;
      });

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          inputsFrom = [ (self.lib.mkOpenCodeShell { inherit system; }) ];
          env.AI_CONFIG_DIR = "./data";
        };
      });
    };
}
