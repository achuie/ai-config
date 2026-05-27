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
      lib.mkOpenCodeShell =
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
            ]
            ++ extraPackages pkgs
          );

          # Shared bash preamble: guard, HOME redirect, dir creation.
          # REAL_HOME is captured here before the redirect for use by the
          # macOS seatbelt wrapper; it is set but unused on Linux.
          commonPrologue = ''
            set -euo pipefail

            if [ -z "''${AI_CONFIG_DIR:-}" ]; then
              echo "AI_CONFIG_DIR not set" >&2
              exit 1
            fi

            # Capture real home before redirecting HOME (used on macOS).
            REAL_HOME="$HOME"

            HOME="$AI_CONFIG_DIR/home"
            export HOME

            mkdir -p \
              "$HOME/.config/opencode" \
              "$HOME/.local/share/opencode" \
              "$HOME/.local/state/opencode" \
              "$HOME/.cache/opencode"
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
                    --ro-bind /nix/store /nix/store \
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
                    --bind "$(pwd -P)" /workspace \
                    --dir /usr/bin \
                    --symlink ${pkgs.coreutils}/bin/env /usr/bin/env \
                    --chdir /workspace \
                    --setenv HOME "$HOME" \
                    --setenv USER "$_USERNAME" \
                    --setenv LOGNAME "$_USERNAME" \
                    --setenv OPENCODE_CONFIG_DIR "$HOME/.config/opencode" \
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
                  export OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
                  export USER="$(id -un)"
                  export LOGNAME="$USER"
                  export TMPDIR="''${TMPDIR:-/tmp}"

                '' + cmdDispatch + ''
                  exec /usr/bin/sandbox-exec \
                    -D REAL_HOME="$REAL_HOME" \
                    -D HOME_DIR="$HOME" \
                    -D WORKSPACE="$(pwd -P)" \
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

        in pkgs.mkShell {
          packages = [ opencodeWrapped ];
        };

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          inputsFrom = [ (self.lib.mkOpenCodeShell { inherit system; }) ];
          env.AI_CONFIG_DIR = "./data";
        };
      });
    };
}
