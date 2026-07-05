# ai-config

Persistent [opencode](https://opencode.ai) configuration, auth, and chat history as a Nix flake.
Built on bubblewrap for sandboxing on Linux.

All session history, model preferences, cached packages, and API auth live in `data/` (gitignored),
and are shared across every project that imports this flake.

## Repo layout

```
ai-config/
├── flake.nix              # The flake which exposes packages, apps, lib.mkOpenCodeShell
├── config/
│   ├── opencode.jsonc     # opencode configuration, location set by OPENCODE_CONFIG_DIR
│   └── skills/
└── data/                  # Persistent state (gitignore'd)
    └── home/
        ├── .local/share/opencode/   # Sessions, SQLite DB, auth
        │   └── auth.json
        ├── .local/state/opencode/   # Model prefs, prompt history
        ├── .cache/opencode/         # Cached model list, packages
        └── .config/opencode/        # Plugin node_modules
```

## Install

Install the wrapper into your profile:

```sh
nix profile install github:achuie/ai-config
```

Then run it from any project directory:

```sh
cd ~/projects/my-project
opencode-wrapped
```

To inspect the resolved state and workspace paths without launching opencode:

```sh
opencode-wrapped --where
```

The current directory is mounted read/write as `/workspace` inside the sandbox,
and opencode starts there. Nix is available in the sandbox by default, so the
model can use commands such as `nix shell`, `nix run`, and `nix develop` to add
tools when needed.

Persistent opencode state defaults to `$XDG_DATA_HOME/ai-config` when
`XDG_DATA_HOME` is set, otherwise `$HOME/.local/share/ai-config`.

## Setup From A Clone

### 1. Clone this repo

```sh
git clone git@github.com:achuie/ai-config.git ~/projects/ai-config
```

### 2. Optional: export `AI_CONFIG_DIR`

`AI_CONFIG_DIR` overrides the default state root. It should point at the state
root (`data/`), not the repository root. When using this flake directly from a
clone, set this before entering the shell if you want state stored in the clone:

```sh
export AI_CONFIG_DIR=~/projects/ai-config/data
```

When using via a project flake, you can still set it declaratively in that
flake's `mkShell` instead (see [Using in a project flake](#using-in-a-project-flake)).

The flake resolves `HOME` and all XDG state directories relative to this path at runtime.

### 3. (Optional) Export `OPENCODE_API_KEY`

If you prefer not to rely on the `auth.json` file:

```sh
export OPENCODE_API_KEY=your-key-here
```

## Using This Repo Directly

```sh
cd ~/projects/ai-config
nix develop
opencode-wrapped
```

You can also run the package without installing it:

```sh
cd ~/projects/my-project
nix run ~/projects/ai-config
```

## Using in a project flake

Add this flake as an input, call `lib.mkOpenCodeShell`, and compose it into
your project's devShell using `inputsFrom`. You can set `AI_CONFIG_DIR`
declaratively in the same shell to choose a specific shared state location:

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
        env.AI_CONFIG_DIR = "/home/achuie/projects/ai-config/data";
      };
    };
}
```

Then in your project:

```sh
nix develop
opencode-wrapped
```

opencode will have access to your full chat history, API auth, model preferences,
Nix, and any extra tools declared in `extraPackages`.

## Installable outputs

| Output                               | Description                 |
|--------                              |-------------                |
| `packages.<system>.opencode-wrapped` | Installable wrapper package |
| `packages.<system>.default`          | Same as `opencode-wrapped`  |
| `apps.<system>.opencode-wrapped`     | Runnable flake app          |
| `apps.<system>.default`              | Same as `opencode-wrapped`  |

## Library arguments

| Argument        | Required | Description                                                   |
|---------------- |----------|-------------                                                  |
| `system`        | yes      | The Nix system string, e.g. `"x86_64-linux"`                  |
| `extraPackages` | no       | Function `pkgs: [ ... ]` — packages added to the sandbox PATH |

`lib.mkOpenCodePackage` builds the installable wrapper. `lib.mkOpenCodeShell`
wraps that package in a dev shell for project flakes.

## Runtime environment variables

| Variable                                     | Required | Description                                                                                               |
|------------------                            |----------|-------------                                                                                              |
| `AI_CONFIG_DIR`                              | no       | Optional path to the state root; defaults to `$XDG_DATA_HOME/ai-config` or `$HOME/.local/share/ai-config` |
| `OPENCODE_API_KEY`                           | no       | API key — falls back to `auth.json` if unset                                                              |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`       | no       | Passed through to opencode for git identity                                                               |
| `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL` | no       | Passed through to opencode for git identity                                                               |
