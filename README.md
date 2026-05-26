# ai-config

Persistent [opencode](https://opencode.ai) configuration, auth, and chat history as a Nix flake.
Built on bubblewrap for sandboxing on Linux.

All session history, model preferences, cached packages, and API auth live in `data/` (gitignored),
and are shared across every project that imports this flake.

## Repo layout

```
ai-config/
├── flake.nix              # The flake (exposes lib.mkOpenCodeShell)
├── config/
│   └── opencode.jsonc     # opencode configuration (OPENCODE_CONFIG_DIR)
│   └── skills/
└── data/                  # Persistent state (gitignored)
    └── home/
        ├── .local/share/opencode/   # Sessions, SQLite DB, auth
        │   └── auth.json
        ├── .local/state/opencode/   # Model prefs, prompt history
        ├── .cache/opencode/         # Cached model list, packages
        └── .config/opencode/        # Plugin node_modules
```

## Setup

### 1. Clone this repo

```sh
git clone git@github.com:achuie/ai-config.git ~/projects/ai-config
```

### 2. Export `AI_CONFIG_DIR`

When using this flake directly (not via a project flake), set this before entering the shell:

```sh
export AI_CONFIG_DIR=~/projects/ai-config
```

When using via a project flake, set it declaratively in that flake's `mkShell` instead
(see [Using in a project flake](#using-in-a-project-flake)).

The flake resolves all state directories and `OPENCODE_CONFIG_DIR` relative to this path at runtime.

### 3. (Optional) Export `OPENCODE_API_KEY`

If you prefer not to rely on the `auth.json` file:

```sh
export OPENCODE_API_KEY=your-key-here
```

## Using in this repo directly

```sh
cd ~/projects/ai-config
nix develop
opencode
```

## Using in a project flake

Add this flake as an input, call `lib.mkOpenCodeShell`, and compose it into
your project's devShell using `inputsFrom`. Set `AI_CONFIG_DIR` declaratively
in the same shell so it is always available without any manual exports:

```nix
# flake.nix in your project
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ai-config = {
      url = "github:achuie/ai-config";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, ai-config, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      opencodeShell = ai-config.lib.mkOpenCodeShell {
        system = "x86_64-linux";
        # Add any tools your project needs inside the opencode sandbox:
        extraPackages = pkgs: [
          pkgs.nodejs
          pkgs.python3
          pkgs.rustc
          pkgs.cargo
        ];
      };
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        inputsFrom = [ opencodeShell ];
        env.AI_CONFIG_DIR = "/home/achuie/projects/ai-config";
      };
    };
}
```

Then in your project:

```sh
nix develop
opencode
```

opencode will have access to your full chat history, API auth, model preferences,
and any extra tools declared in `extraPackages`.

## `mkOpenCodeShell` arguments

| Argument        | Required | Description |
|----------------|----------|-------------|
| `system`        | yes      | The Nix system string, e.g. `"x86_64-linux"` |
| `extraPackages` | no       | Function `pkgs: [ ... ]` — packages added to the sandbox PATH |

## Runtime environment variables

| Variable          | Required | Description |
|------------------|----------|-------------|
| `AI_CONFIG_DIR`   | **yes**  | Absolute path to this repo |
| `OPENCODE_API_KEY` | no      | API key — falls back to `auth.json` if unset |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | no | Passed through to opencode for git identity |
| `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL` | no | Passed through to opencode for git identity |
