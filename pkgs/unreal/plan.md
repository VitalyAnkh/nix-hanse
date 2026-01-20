# UE5 on NixOS packaging plan (pkgs/unreal)

> **Single source of truth** for this task: this file (`pkgs/unreal/plan.md`).
>
> Scope: only modify files under `pkgs/unreal/`.
>
> Hard constraint: **do not modify** anything under `~/projects/dev/cpp/UnrealEngine` (no patches/edits/config/submodules). Build-generated artifacts are assumed OK **only if** they do not change tracked sources; if this assumption is wrong, we will switch to building from a copied `src` in the Nix store.

## Context

- Goal: Package **Unreal Engine 5** on NixOS with a flake.
- UE source location (fixed): `~/projects/dev/cpp/UnrealEngine`
- Starting point: `pkgs/unreal/flake.nix` is a copy of nix-warez blender flake; must be converted to UE.
- Inputs already present from nixpkgs issue #124963: `pkgs/unreal/shell.nix` and `pkgs/unreal/.envrc`.

## External references (must read + map to Nix)

- Unreal official Linux build README: `Engine/Build/BatchFiles/Linux/README.md` (EpicGames/UnrealEngine repo)
- AUR `unreal-engine` PKGBUILD: https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=unreal-engine
- nixpkgs issue #124963: https://github.com/NixOS/nixpkgs/issues/124963

## Current local state (inventory)

### `pkgs/unreal/` files

- Present: `.envrc`, `flake.nix` (Blender), `shell.nix` (FHS env)
- Missing (will create): `unreal.nix`, `plan.md` (this), maybe helper scripts under `pkgs/unreal/`

### Initial read (2026-01-16)

- `pkgs/unreal/flake.nix`: Blender upstream-binaries flake (copied from nix-warez). We temporarily added `devShells.x86_64-linux.default = import ./shell.nix { ... }` so the direnv pattern from issue #124963 can work once flake fetching is fixed.
- `pkgs/unreal/shell.nix`: `buildFHSEnv` named `UnrealEditor` (copied from issue #124963; will be adjusted as needed for our environment constraints below).
- `pkgs/unreal/.envrc`: acts as a *launcher* into `nix-shell ./shell.nix` (with an `FHS_CURRENT` recursion guard) and sets `NIX_CONFIG` to prefer `https://cache.nixos.org` (to avoid incomplete mirrors).

## Environment constraints discovered (2026-01-16)

- Bandwidth to `cache.nixos.org` is extremely low in this session (~36 KB/s measured via a 1MiB ranged download), making large nixpkgs substitutions impractical.
- During early attempts we created **invalid/partial** store paths for large deps (e.g. `dotnet-sdk`, `mono`, `clang-*-lib`):
  - `nix-store --verify-path` reports them as *not valid*
  - `du -sh` shows they are incomplete (e.g. `dotnet-sdk` ~13 MiB, `mono` <1 MiB).
- Consequence: Phase 1 must avoid pulling heavyweight toolchains (`dotnet-sdk`, `clang`) from nixpkgs caches.
- Mitigation: Phase 1 will rely on **UE’s bundled toolchain + dotnet** installed by `Setup.sh` / `Engine/Build/BatchFiles/Linux/SetupToolchain.sh` (per `Engine/Build/BatchFiles/Linux/Setup.sh`: “Both dotnet and the compiler toolchain are now bundled.”). Nix will focus on runtime libs + small build utilities.
- Nix flake “git+file” gotcha:
  - When running `nix` flake commands in a git repo, Nix defaults to `git+file://...` and **excludes untracked files** from the flake source.
  - Since this task requires creating new files under `pkgs/unreal/` (e.g. `unreal.nix`) and we are not modifying git metadata, we will use `path:.` flake refs for validation (e.g. `cd pkgs/unreal && nix build path:.#unreal-engine`).

## Milestones / phases

### Phase 0 — Research + mapping (required before implementation)

**Goal:** Extract the exact Linux build steps + deps, and the PKGBUILD “prepare/build/package” logic; map them to Nix primitives (`mkDerivation`, `buildFHSEnv`, wrappers, env vars).

Steps:

0.1 Read Unreal Linux README and record:
  - toolchain requirements (clang version, mono/.NET usage, cmake, python, etc)
  - required system libs (X11, Wayland, Vulkan, audio)
  - canonical build commands (`Setup.sh`, `GenerateProjectFiles.sh`, `Build.sh`, run Editor)
  - any special env vars / ulimits / filesystem expectations

0.2 Read AUR PKGBUILD and record:
  - build dependencies (system packages)
  - `prepare()` steps (patches, setup scripts, dependency downloads, generating project files)
  - `build()` steps (targets built, configs, parallelism)
  - `package()` layout (install paths, wrappers, icons/desktop files, permissions)
  - any explicit flags/patches we must translate (as Nix expressions)

0.3 Read nixpkgs issue #124963 and record:
  - the exact `shell.nix`/`.envrc` approach used to get UE building on NixOS
  - missing libs/env vars that caused prior failures
  - any known caveats (sandboxing, FHS env, `NIX_LD`, dotnet)

**Validation:** none (research-only), but record quotes/snippets/links and a mapping table to Nix.

#### Phase 0 findings (2026-01-16)

**Unreal Linux README (local copy: `~/projects/dev/cpp/UnrealEngine/Engine/Build/BatchFiles/Linux/README.md`)**

- Canonical flow:
  - `./Setup.sh` (downloads “binary files too large for git” via GitDependencies; registers post-merge hook; also builds LinuxNativeDialogs)
  - `./GenerateProjectFiles.sh`
  - build via `make` (or explicit targets; older doc lists `CrashReportClient ShaderCompileWorker UnrealLightmass InterchangeWorker UnrealPak UnrealEditor`)
  - run: `Engine/Binaries/Linux/UnrealEditor` (optionally with `~/.../*.uproject`)
- Practical notes to keep in mind for Nix:
  - First start creates/populates `Engine/DerivedDataCache`
  - Needs large `ulimit -n` (mentions 16000+ file handles)
  - Setup may loop if the downloader crashes (watch `Engine/Build/BatchFiles/Linux/BuildThirdParty.log` on failure)

**AUR PKGBUILD (`/tmp/aur-unreal-engine/PKGBUILD`, pkgver=5.5.0)**

- Key inputs:
  - Toolchain tarball from Epic CDN: `${UE_SDK_VERSION}.tar.gz` (example: `native-linux-v23_clang-18.1.0-rockylinux8`)
  - Env workaround: `DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER=0`
  - Optional patch: `use_system_clang.patch` controlled by `_use_system_clang`
  - Optional “pre-build DerivedDataCache”: `_WithDDC` toggles BuildGraph arg `-set:WithDDC=true/false`
- `prepare()` logic to port:
  - Ensure access to private EpicGames/UnrealEngine git (uses SSH URL)
  - Clone/update `${pkgname}` repo; reset to `${pkgver}-release`
  - Optionally apply `use_system_clang.patch`
  - Clone QtCreatorSourceCodeAccess plugin into `Engine/Plugins/Developer/` if missing
  - Ensure file exists: `Engine/Source/ThirdParty/Linux/HaveLinuxDependencies` (creates + writes 1st line) to avoid build failure
  - Run `./Setup.sh`
  - Install toolchain:
    - AUR comments say `SetupToolchain.sh` isn’t reliable; PKGBUILD manually untars SDK to `Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/`
  - Run:
    - `Engine/Build/BatchFiles/Linux/BuildThirdParty.sh`
    - `Engine/Build/BatchFiles/Linux/SetupDotnet.sh`
    - `Engine/Build/BatchFiles/Linux/FixDependencyFiles.sh`
- `build()` logic to port:
  - Uses BuildGraph via UAT:
    - `Engine/Build/BatchFiles/RunUAT.sh BuildGraph -target="Make Installed Build Linux" -script=Engine/Build/InstalledEngineBuild.xml ...`
    - Sets `WithLinux=true`, `WithWin64=true`, others false; `HostPlatformOnly=false`
  - Output is `LocalBuilds/Engine/Linux/...` (an “installed build” layout)
- `package()` logic to port (Nix “installPhase” equivalent):
  - Desktop entry edits to point Exec to `/usr/bin/unreal-engine-5.sh %U` and icon `ue5editor`
  - Installs wrapper script (`unreal-engine-5.sh`) + symlinks (`ue5`, `UE5`, `unreal-engine-5`)
  - Copies `LocalBuilds/Engine/Linux/*` and then the rest of the repo into install dir (`_ue5_install_dir`, default `opt/unreal-engine`)
  - Very permissive permissions (`chmod -R 777`), plus ensuring `xbuild`/`mcs` are executable

**nixpkgs issue #124963 (GitHub API)**

- Issue body (2021-05-30): the canonical “newbie” flow matches the Linux README (`Setup.sh`, `GenerateProjectFiles.sh`, `make`) and notes `/bin/bash` shebang + dotnet/mono pain points.
- Comment by `Murazaki` (2025-12-04): provides exactly the `shell.nix` + `.envrc` we have copied:
  - `buildFHSEnv` with `llvmPackages_20.stdenv`, `clang_20`, SDL3, Vulkan, X11+Wayland stack
  - sets `NIX_LD` and `NIX_LD_LIBRARY_PATH`
  - exports `DOTNET_ROOT` and `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`
  - `.envrc` runs `nix develop --impure` guarded by `FHS_CURRENT` to avoid direnv recursion/looping
- Other useful tidbits in the thread:
  - Running Epic-provided binaries works for some users via `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 steam-run ./Engine/Binaries/Linux/UnrealEditor` (helps validate our dependency/env assumptions).

**Mapping to Nix implementation (next actions)**

- Phase 1 env entry:
  - Provide a flake `devShell` that uses `shell.nix` so the `.envrc`’s `nix develop --impure` works unchanged.
- `unreal.nix` (Phase 2):
  - Implement a derivation that can run the PKGBUILD’s `prepare/build/package` steps, but guard the networked parts (Setup/toolchain download) behind explicit options because Nix sandbox builders cannot fetch at build time.
  - Start with “installed build” flow (BuildGraph) since that matches PKGBUILD and yields a relocatable `LocalBuilds/Engine/Linux` tree suitable for `$out`.

## Porting map (PKGBUILD → Nix)

Inputs:
- AUR PKGBUILD: `/tmp/aur-unreal-engine/PKGBUILD` (pkgver `5.5.0`) + wrapper `unreal-engine-5.sh`
- Epic Linux README (local clone): `~/projects/dev/cpp/UnrealEngine/Engine/Build/BatchFiles/Linux/README.md`
- nixpkgs issue #124963: https://github.com/NixOS/nixpkgs/issues/124963

| PKGBUILD section | Key intent / commands | Nix implementation (this repo) |
|---|---|---|
| `prepare()` | Ensure repo is prepared; run `./Setup.sh`; set up toolchain + dotnet; run `BuildThirdParty.sh`, `SetupDotnet.sh`, `FixDependencyFiles.sh` | **Phase 1** executed in the local clone inside FHS (`pkgs/unreal/plan.md` “Phase 1”). For Phase 2 we provide the FHS wrapper app `nix run path:.#unreal-fhs` (from `pkgs/unreal/flake.nix`) so these scripts can run with `/bin/bash` present. |
| `build()` | Build an “installed build” via `RunUAT.sh BuildGraph -target="Make Installed Build Linux" -script=Engine/Build/InstalledEngineBuild.xml ...` and optionally `-set:WithDDC=true/false` | Implemented as flake app `nix run path:.#unreal-build-installed -- --with-ddc=...` (see `pkgs/unreal/flake.nix`). We also pass `-set:BuiltDirectory=...` (supported by `InstalledEngineBuild.xml`) to avoid writing `LocalBuilds/` under the UE source tree. |
| `package()` | Copy installed build into install prefix; add launch wrapper(s) and desktop/icon | Implemented as Nix package `unreal-engine-installed` (see `pkgs/unreal/unreal.nix` with `buildInstalled = true`): it packages an *already-built* installed-build tree from `UE_INSTALLED_DIR` (default `~/.cache/unreal-engine/LocalBuilds/Engine/Linux`) into `$out`, adds `$out/bin/UnrealEditor` wrapper that runs inside `ue5-fhs`, and installs desktop/icon files (`com.unrealengine.UE5Editor.desktop`, `ue5editor.svg`) ported from PKGBUILD. |
| Helper wrapper script | Ensure user dirs exist, launch via `.desktop` entry | Not ported 1:1. On NixOS we use the FHS wrapper + `UnrealEditor` wrappers; user dir initialization is currently left to UE itself / runtime defaults. |

### Phase 1 — Build & run UE5 using `shell.nix` + `.envrc` (no UE source edits)

**Goal:** With the existing UE clone at `~/projects/dev/cpp/UnrealEngine`, enter a reproducible dev environment from `pkgs/unreal/` and successfully:

- compile `UnrealEditor` (or confirm it is already built), and
- run it to a clearly observable stage (at least `UnrealEditor -help` / `-version`, ideally starts UI with `-log`).

Steps (small diffs only):

1.1 Make direnv entry work using `pkgs/unreal/shell.nix`.
  - Reality check: `nix develop` currently fails while fetching `nixpkgs` (tarball read error), so Phase 1 will use **non-flake** direnv integration first.
  - Files to modify (minimal):
    - `pkgs/unreal/.envrc` (switch to `use nix ./shell.nix`)
    - (keep `pkgs/unreal/flake.nix` devShell addition; we’ll fix flake fetching separately during Phase 2)
  - Command to validate:
    - `cd pkgs/unreal && direnv allow && direnv exec . bash -lc 'echo IN_NIX_SHELL=$IN_NIX_SHELL; clang --version | head -n 1; dotnet --info | head -n 5; echo NIX_LD=$NIX_LD'`
  - Success: command runs inside nix env; required tools visible.

1.2 In the dev env, validate UE source directory is untouched (no tracked changes).
  - Command:
    - `cd ~/projects/dev/cpp/UnrealEngine && git status --porcelain`
  - Success: no modified tracked files (untracked build artifacts OK if ignored; if not ignored, we will revisit the “no modifications” constraint with user).

1.3 Build UE per official Linux README (or skip steps already done):
  - Commands (run inside the dev env):
    - `cd ~/projects/dev/cpp/UnrealEngine`
    - `./Setup.sh` (if dependencies not present; note this may download content)
    - `./GenerateProjectFiles.sh` (if needed)
    - `./Engine/Build/BatchFiles/Linux/Build.sh UnrealEditor Linux Development -Progress`
  - Success: `Engine/Binaries/Linux/UnrealEditor` exists and is executable.

1.4 Run UE editor inside the dev env:
  - Command:
    - `~/projects/dev/cpp/UnrealEngine/Engine/Binaries/Linux/UnrealEditor -help` (minimal)
    - (optional) `.../UnrealEditor -log` (UI startup)
  - Success: prints help/version or starts to UI/log without missing-lib errors.

After each sub-step: append the exact command run + key log lines + result to **this file**.

### Phase 2 — Convert Blender flake → UE flake; migrate `shell.nix`/`.envrc` into `flake.nix`

**Goal:** `pkgs/unreal/flake.nix` provides:

- `devShells.x86_64-linux.default` with the working UE build environment (Phase 1 parity)
- `packages.x86_64-linux.unreal-engine` built/installed via `pkgs/unreal/unreal.nix`
- optionally `apps.x86_64-linux.unreal-editor` to run Editor via `nix run`

Steps:

2.0 Fix flake evaluation / nixpkgs fetch corruption (tarball read errors).
  - Problem symptoms seen earlier:
    - `nix develop` fails with `cannot read file ... from tarball` (missing file inside nixpkgs source)
  - Attempt order (do *not* repeat the same failed action unchanged):
    - A) Reproduce + capture exact error/store path:
      - `cd pkgs/unreal && nix flake metadata --refresh`
      - `cd pkgs/unreal && nix develop --impure -c true`
    - B) If the error mentions a specific `/nix/store/<...>-source` path, delete it and retry:
      - `nix-store --delete /nix/store/<...>-source`
      - retry `nix flake metadata --refresh`
    - C) If it still fails, switch nixpkgs input to a git fetcher (avoids GitHub tarball path entirely), then re-lock:
      - edit `pkgs/unreal/flake.nix`: `inputs.nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-25.11";`
      - `cd pkgs/unreal && nix flake lock --recreate-lock-file --refresh`
    - D) If GitHub access is flaky (TLS/EOF), temporarily switch nixpkgs input to a local `path:` snapshot (system channels) to unblock Phase 2.
    - E) If `nix develop -c ...` still doesn't behave (common with `buildFHSEnv`), export the FHS wrapper as a flake `package/app` so we can validate via `nix run`.
  - Validation / success criteria:
    - `cd pkgs/unreal && nix flake metadata --refresh` succeeds
    - Either:
      - `cd pkgs/unreal && nix develop --impure -c bash -lc 'echo OK; uname -a | head -n1'` succeeds, **or**
      - `cd pkgs/unreal && nix run path:.#unreal-fhs -- -lc 'echo OK; uname -a | head -n1'` succeeds

2.1 Create `pkgs/unreal/unreal.nix` by porting the AUR PKGBUILD:
  - Implement `mkDerivation` with phases mirroring `prepare/build/package`
  - Decide on `src` strategy:
    - default: **impure** `src` from `$UE_SRC` env var (points to local clone)
    - optional: pure `src` from `builtins.path` (copies local tree into store; expensive but avoids touching working tree)
  - Provide wrapper script(s) in `$out/bin` (e.g. `UnrealEditor`) setting `LD_LIBRARY_PATH`/`DOTNET_ROOT` as needed.
  - Incremental approach (small diffs):
    - 2.1.1 First make a *wrapper-only* package that runs the already-prepared local clone (Phase 1 output) inside our flake-provided FHS wrapper.
      - Success criteria: `nix build` is fast; `nix run` reaches UE startup (similar to Phase 1 `-nullrhi -help`).
      - This is a pragmatic stepping stone while we refine the full installed-build derivation.
    - 2.1.2 Add an *installed-build* derivation (BuildGraph) mirroring PKGBUILD `build()` + `package()`:
      - `buildPhase`: `RunUAT.sh BuildGraph -target="Make Installed Build Linux" -script=Engine/Build/InstalledEngineBuild.xml ...`
      - `installPhase`: copy `LocalBuilds/Engine/Linux/*` into `$out` and add a wrapper in `$out/bin`.
      - Hard constraint: no network in the Nix builder; therefore require that the input `src` already contains all GitDependencies outputs (prepared via Phase 1 `Setup.sh`).
  - Validation:
    - `cd pkgs/unreal && NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix build path:.#unreal-engine --impure -L`
    - `cd pkgs/unreal && ./result/bin/UnrealEditor -nullrhi -help` (should print `Engine is initialized...` and start loading a map)

2.1.2(continuation) Make the installed-build derivation practical:
  - Problem: `builtins.path` source materialization is huge (tens of GB) before BuildGraph even starts.
  - Step A (diagnose): measure which UE subtrees dominate size, to decide whether we can safely exclude more.
    - Commands (read-only):
      - `du -sh ~/projects/dev/cpp/UnrealEngine/* | sort -h | tail -n 40`
      - `du -sh ~/projects/dev/cpp/UnrealEngine/Engine/* | sort -h | tail -n 40`
      - `du -sh ~/projects/dev/cpp/UnrealEngine/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/* | sort -h | tail -n 20`
    - Success criteria: identify 3–5 biggest dirs and whether they are needed for BuildGraph.
  - Step B (inspect): check whether BuildGraph supports redirecting the installed-build output dir (to avoid touching the UE source tree).
    - Commands (read-only):
      - `rg -n 'LocalBuilds|InstalledBuild|InstallDir|OutputDir|BuildRoot|RootBuild' ~/projects/dev/cpp/UnrealEngine/Engine/Build/InstalledEngineBuild.xml`
      - `rg -n 'LocalBuilds' ~/projects/dev/cpp/UnrealEngine/Engine/Build/InstalledEngineBuild.xml`
    - Success criteria: confirm if there is a `-set:` variable we can pass to control the output location.
  - Step C (practical): export a flake `app` that runs the PKGBUILD BuildGraph command **outside** the Nix builder (inside our FHS wrapper), writing output to a user-chosen directory.
    - Reason: doing the full BuildGraph compile inside a Nix derivation currently requires copying ~100GB+ source into the store and will take hours; for iteration we need a faster loop.
    - Command pattern (to implement as `nix run path:.#unreal-build-installed`):
      - `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build-installed -- --with-ddc=false`
    - Validation (small/fast): `nix run ... -- --help` prints usage and the underlying `RunUAT.sh BuildGraph ...` command line.
    - Validation (medium): run with a short timeout to ensure UAT starts without immediate dependency/shebang errors:
      - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine timeout 60s nix run path:.#unreal-build-installed -- --with-ddc=false`
    - Execution (real / long-running):
      - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build-installed -- --with-ddc=false`
      - Success criteria: `"$UE_BUILTDIR/Linux/Engine/Binaries/Linux/UnrealEditor"` exists (BuildGraph finished).
  - Step D (package): add a derivation that packages an **already-built** installed-build tree (default `${UE_SRC}/LocalBuilds/Engine/Linux`) into `$out`, plus wrapper(s).
    - Validation (fast): if the installed-build dir is missing, the derivation fails with a clear error message.
    - Validation (real): once BuildGraph completed, `nix build path:.#unreal-engine-installed --impure -L` produces `result/Engine/Binaries/Linux/UnrealEditor`, and `timeout 45s result/bin/UnrealEditor -nullrhi -help` reaches `Engine is initialized...`.

2.2 Rewrite `pkgs/unreal/flake.nix`:
  - Replace blender overlay/packages with UE outputs.
  - Export:
    - `devShells.x86_64-linux.default` (either inline or via `import ./shell.nix { pkgs = ...; }`)
    - `packages.x86_64-linux.default = unreal-engine`
  - Validation:
    - `nix develop ./pkgs/unreal --impure -c bash -lc 'clang --version; dotnet --info | head'`
    - `nix build ./pkgs/unreal#unreal-engine --impure -L`

2.3 Update `pkgs/unreal/.envrc` to prefer the flake devShell (no `shell.nix` dependency), but keep a fallback until stable.
  - Validation: `direnv reload` enters the same env as `nix develop`.

## Execution log (append-only)

### 2026-01-16

- ✅ Inventory: `pkgs/unreal/` contains `.envrc`, `flake.nix`, `shell.nix`; no `unreal.nix` yet.
- ✅ Initial reads: captured in “Initial read” above.
- ⚠️ Web fetch notes:
  - AUR cgit is protected by Anubis in this environment (access denied). Plan: use `git clone https://aur.archlinux.org/unreal-engine.git` to fetch `PKGBUILD`.
  - EpicGames/UnrealEngine `README.md` URL returned 404 (expected if repo is private). Plan: read the Linux README from the **local UE clone** at `~/projects/dev/cpp/UnrealEngine/Engine/Build/BatchFiles/Linux/README.md`.
  - GitHub HTML view of nixpkgs issue #124963 loads only the issue body here; plan: use GitHub API to fetch comments (JSON) to extract the referenced `shell.nix` / `.envrc` content.
- ❌ `nix develop` (flake) failure:
  - Command: `cd pkgs/unreal && nix develop --impure -c ...`
  - Error (while fetching flake input `nixpkgs`): `cannot read file '.../pkgs/by-name/cf/cfdyndns/Cargo.lock' from tarball`
  - Next: switch `.envrc` to `use nix` for Phase 1 (avoid flakes), and separately fix flake input fetching (likely cached tarball corruption).
- ❌ `direnv` + `use nix ./shell.nix` failure (binary cache mirror missing NARs):
  - Command: `cd pkgs/unreal && direnv allow && direnv exec . bash -lc '...'`
  - Error: repeated `file 'nar/<...>.nar.xz' does not exist in binary cache 'https://mirrors.ustc.edu.cn/nix-channels/store'`
  - Next: set `NIX_CONFIG` in `pkgs/unreal/.envrc` to force `substituters = https://cache.nixos.org` for this project (avoid broken mirror), then retry.
- ⚠️ Bandwidth + store integrity:
  - Measured `cache.nixos.org` download speed for large NARs: ~36 KB/s (too slow for multi-hundred-MB toolchains).
  - `nix-store --verify-path` shows partial store paths created during interrupted downloads are **not valid** (e.g. `dotnet-sdk`, `mono`, `clang-*-lib`).
- ✅ Adjustments made to avoid heavyweight nixpkgs toolchains:
  - Updated `pkgs/unreal/.envrc` to *exec into* `nix-shell ./shell.nix` once (avoid `nix-direnv` recursion with `buildFHSEnv`) and pin substituters to `https://cache.nixos.org`.
  - Updated `pkgs/unreal/shell.nix` to rely on UE’s bundled toolchain/dotnet and only provide runtime libs + small build tools.
- ❌ Direnv eval error after slimming `shell.nix`:
  - Error: `undefined variable 'sed'` (nixpkgs uses `gnused`, not `sed`).
  - Fix: replaced `sed` with `gnused` in `pkgs/unreal/shell.nix`.
- ✅ Entered the UE dev environment (FHS) successfully:
  - Command: `DIRENV_DISABLE=1 nix-shell pkgs/unreal/shell.nix`
  - Observations inside the shell:
    - `/usr/bin/python3` exists; `IN_NIX_SHELL=impure`; `/usr` has a standard FHS layout.
- ✅ UE tree is clean before setup:
  - Command: `cd ~/projects/dev/cpp/UnrealEngine && git status --porcelain`
  - Result: no output (no tracked changes).
- 🚧 Phase 1 blocker: `Setup.sh` dependency download is too slow to complete in-session:
  - Command: `cd ~/projects/dev/cpp/UnrealEngine && ./Setup.sh --force`
  - Output shows GitDependencies wants **~28911 MiB (~28.9 GiB)** of downloads; observed throughput ~`0.03–0.10 MiB/s` in this session.
  - We aborted with `^C` after ~34s at ~0.6 MiB downloaded (not meaningful progress).
  - GitDependencies cache location (from `--help`): `~/projects/dev/cpp/UnrealEngine/.git/ue-gitdeps` (it should resume if restarted).
  - Next action required to unblock Phase 1:
    - Run `./Setup.sh --force` to completion on a faster connection (or with an HTTP proxy).
    - Optional size reduction attempt: set `UE_GITDEPS_ARGS="--exclude=Win64 --exclude=Mac --exclude=Android --exclude=IOS --exclude=TVOS --exclude=HoloLens --exclude=PS4 --exclude=PS5 --exclude=XboxOne --exclude=Scarlett --exclude=Switch"` and rerun `./Setup.sh --force` (still may be large; must validate).
- ⚠️ `nix-shell --run/--command` caveat with `buildFHSEnv`:
  - In this setup, `nix-shell <shell.nix> --run '...'` does **not** reliably execute the command inside the FHS container; it tends to just drop into an interactive FHS shell prompt.
  - Verified via process tree: the `--run` attempt started a `bwrap` container with only an idle `bash` inside (no `Setup.sh` child process).
  - Practical workflow (works and fixes `/bin/bash` shebang on NixOS):
    - `DIRENV_DISABLE=1 nix-shell pkgs/unreal/shell.nix`
    - then run `cd ~/projects/dev/cpp/UnrealEngine && ./Setup.sh --force` (or `bash ./Setup.sh --force`) inside that shell.

- ✅ `Setup.sh --force` is now running (download resumed):
  - We found the previously-started `./Setup.sh --force` still running in the background (PIDs: `Setup.sh=2275621`, `GitDependencies.sh=2275629`, `GitDependencies=2275634`).
  - Validation: `du -sh ~/projects/dev/cpp/UnrealEngine/.git/ue-gitdeps` shows progress:
    - was ~`4.1G`
    - now ~`26G` (download is actively progressing).
  - Next: wait for `Setup.sh` to exit successfully, then proceed to `GenerateProjectFiles.sh` + build.
  - ✅ Update: `Setup.sh` completed successfully.
    - `du -sh ~/projects/dev/cpp/UnrealEngine/.git/ue-gitdeps` → `29G`
    - `Engine/Build/OneTimeSetupPerformed` exists.
    - Bundled toolchain installed: `Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v26_clang-20.1.8-rockylinux8` (~`3.4G`).
    - UE tree still clean (tracked files): `git status --porcelain` → empty.

 - ✅ Added missing archive tools to the FHS env (needed by `SetupToolchain.sh`):
   - File changed: `pkgs/unreal/shell.nix` (added `gnutar` + `gzip` to `tools`)
   - Validation (inside FHS): `command -v tar` → `/usr/bin/tar`, `command -v gzip` → `/usr/bin/gzip`

 - ✅ `GenerateProjectFiles.sh` succeeded inside the FHS env:
   - Command: `cd ~/projects/dev/cpp/UnrealEngine && ./GenerateProjectFiles.sh`
   - Key output:
     - Bundled DotNet SDK setup succeeded (`SDK Version: 8.0.412`)
     - UnrealBuildTool built successfully
     - `Result: Succeeded`
     - Note: `Some Platforms were skipped due to invalid SDK setup: Android.`
   - Validation: `git status --porcelain` still empty (no tracked changes).

 - 🚧 `UnrealEditor` build started (in progress):
   - Command:
     - `ulimit -n 16000`
     - `./Engine/Build/BatchFiles/Linux/Build.sh UnrealEditor Linux Development -Progress`
   - Early output:
     - UHT succeeded; toolchain: `v26_clang-20.1.8-rockylinux8`
     - `Using Unreal Build Accelerator local executor to run 5149 action(s)`
     - Warnings observed (may be benign): `getprotobyname returned null for tcp`
   - Latest observed progress: `@progress 'Compiling C++ source code...' 95%` (around action `4864/5149`).
   - Milestone reached: `Engine/Binaries/Linux/UnrealEditor` now exists and is executable.
   - ✅ Update: build completed successfully.
     - `Result: Succeeded`
     - Total execution time: ~`4803s` (~`1h20m`)

 - ✅ Built `ShaderCompileWorker` (required to launch editor):
   - Command: `./Engine/Build/BatchFiles/Linux/Build.sh ShaderCompileWorker Linux Development -Progress`
   - Result: `Succeeded` (total execution time: ~`150s`)

 - ✅ Ran UE5 editor to an observable stage (Phase 1 goal):
   - Command (headless-ish): `./Engine/Binaries/Linux/UnrealEditor -nullrhi -help`
   - Observed (logs):
     - `Engine is initialized. Leaving FEngineLoop::Init()`
     - `Total Editor Startup Time, took 35.304`
     - Started loading the template map: `OpenWorld.umap`
   - Notes:
     - `-help` does **not** exit immediately; we terminated the process after confirming startup.
     - Running the editor created an untracked `Engine/Config/DefaultEngine.ini`; we removed it to keep `git status --porcelain` clean.

## Notes for quick questions

- To run `Setup.sh` (or any UE script with a `/bin/bash` shebang) *without* entering the FHS shell interactively, use the flake app wrapper:
  - `cd pkgs/unreal && nix run path:.#unreal-fhs -- -lc 'cd ~/projects/dev/cpp/UnrealEngine && ./Setup.sh --force'`
  - This executes inside the same `buildFHSEnv` that provides `/bin/bash` on NixOS.

## Phase 2 execution log (append-only)

### 2026-01-16 (Phase 2 start)

- ❌ 2.0(A) `nix flake metadata --refresh` failed fetching nixpkgs tarball from GitHub:
  - Command: `cd pkgs/unreal && nix flake metadata --refresh`
  - Error: `unable to download ...nixpkgs/archive/<rev>.tar.gz: SSL connect error (35) ... unexpected eof while reading`
  - Next attempt: switch nixpkgs input to a git fetcher (`git+https://...`) and re-lock (2.0(C)); if GitHub TLS remains flaky, fall back to a local `path:` nixpkgs input to unblock Phase 2 work.

- ❌ 2.0(C) Switching to `git+https://github.com/NixOS/nixpkgs?ref=nixos-25.11&shallow=1` still fails (GitHub TLS):
  - File changed: `pkgs/unreal/flake.nix`
  - Command: `cd pkgs/unreal && nix flake lock --recreate-lock-file --refresh`
  - Error: `fatal: unable to access 'https://github.com/NixOS/nixpkgs/': TLS connect error ... unexpected eof while reading`
  - Also: `error: resolving Git reference 'nixos-25.11': revspec 'nixos-25.11' not found` (expected after failed fetch)
  - Next attempt: switch nixpkgs input to a local `path:` snapshot (from `/nix/var/nix/profiles/.../channels`) so we can proceed with Phase 2 packaging work without GitHub access.

- ✅ 2.0(D) Switched nixpkgs input to a local channel store path and updated `flake.lock`:
  - File changed: `pkgs/unreal/flake.nix` (now uses `path:/nix/store/.../nixos`)
  - Command: `cd pkgs/unreal && nix flake lock --refresh`
  - Result: succeeded; `flake.lock` now pins the local nixos-25.05 channel snapshot path.
  - Validation: `cd pkgs/unreal && nix flake metadata` succeeds.

- ⚠️ 2.0(E) `nix develop -c ...` appears unreliable with `buildFHSEnv` devShells:
  - Command: `cd pkgs/unreal && nix develop --impure -c bash -lc 'echo OK; ...'`
  - Observed: downloads + builds the FHS env successfully, then appears to hang (no command output); we killed the spawned `bwrap` processes.
  - Next: export a `buildFHSEnv` *wrapper* as a flake `package/app` (not just `.env`) so we can do true non-interactive validation like `nix run .#unreal-fhs -- -lc 'echo OK'`.

- ✅ 2.0(F) Exported a flake `package` + `app` for the FHS wrapper and validated non-interactive execution:
  - Files changed: `pkgs/unreal/flake.nix`, `pkgs/unreal/shell.nix`
  - Command:
    - `cd pkgs/unreal && NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix run .#unreal-fhs -- -lc 'echo OK; uname -a | head -n1; command -v bash; test -x /bin/bash && echo /bin/bash=OK'`
  - Result: succeeded; printed `OK`, `uname`, and confirmed `/bin/bash` exists inside the FHS env.

### 2026-01-16 (Phase 2: unreal.nix wrapper-first)

- ✅ 2.1.1 Added `pkgs/unreal/unreal.nix` (wrapper-first), wired into flake, and validated `nix build` + run:
  - Files changed: `pkgs/unreal/unreal.nix`, `pkgs/unreal/flake.nix`
  - Build (wrapper package; fast):
    - `cd pkgs/unreal && NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix build path:.#unreal-engine --impure -L`
  - Run (headless-ish, bounded):
    - `cd pkgs/unreal && timeout 45s ./result/bin/UnrealEditor -nullrhi -help`
    - Key observed log line: `LogInit: Display: Engine is initialized. Leaving FEngineLoop::Init()`
  - ⚠️ Side-effect: running from the *source tree* creates an untracked file:
    - `cd ~/projects/dev/cpp/UnrealEngine && git status --porcelain` → `?? Engine/Config/DefaultEngine.ini`
    - Cleanup: removed it (`rm -f Engine/Config/DefaultEngine.ini`) to restore `git status --porcelain` to empty.
  - Implication for Phase 2.1.2:
    - A read-only install location (Nix store) will likely require an *installed build* layout (BuildGraph) and/or a wrapper that redirects writable config/caches to `$XDG_*` locations.

- ✅ 2.3 Updated `pkgs/unreal/.envrc` to use the flake-provided FHS app (migration away from `shell.nix`):
  - File changed: `pkgs/unreal/.envrc`
  - Behavior: on entry, sets `NIX_CONFIG` (force `cache.nixos.org`) and `exec nix run path:.#unreal-fhs`
  - Validation: `bash -n pkgs/unreal/.envrc` → OK

### 2026-01-19 (date correction + next step)

- NOTE: This session is on **2026-01-19**; the headings above that say 2026-01-16 were inherited from earlier history in this file. The wrapper/flake/envrc work immediately above was executed on 2026-01-19.
- 🚧 2.1.2 Started the installed-build derivation (BuildGraph) build:
  - Command: `cd pkgs/unreal && NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix build path:.#unreal-engine-installed --impure -L`
  - Status: currently running; initial phase appears to be hashing/copying the large UE source tree into the Nix store (no BuildGraph output yet).

- 🛑 2.1.2 Build interrupted during the initial source materialization step:
  - Observed: Nix created a temp store dir `/nix/store/tmp-1274469-0` that grew to ~`77G` while hashing/copying the UE source tree (filtered to exclude `.git`, `Engine/DerivedDataCache`, etc).
  - Action: interrupted the build (`kill`), then removed the temp dir to free disk:
    - `rm -rf /nix/store/tmp-1274469-0`
  - Next: if we want to complete 2.1.2, expect this initial copy+hashing step to take a while and use tens of GB before BuildGraph even starts; we can also consider tightening the `filteredSrc` filter (drop non-Linux toolchains/assets) once we confirm which subtrees are actually required for BuildGraph on our UE version.

- ✅ 2.1.2(A) Size diagnosis (to guide `filteredSrc` tuning):
  - Commands:
    - `du -sh ~/projects/dev/cpp/UnrealEngine/* | sort -h | tail -n 40`
    - `du -sh ~/projects/dev/cpp/UnrealEngine/Engine/* | sort -h | tail -n 60`
  - Key results:
    - `~/projects/dev/cpp/UnrealEngine/Engine` ≈ `122G`
    - Biggest Engine subtrees:
      - `Engine/Plugins` ≈ `39G`
      - `Engine/Source` ≈ `35G`
      - `Engine/Binaries` ≈ `26G`
      - `Engine/Intermediate` ≈ `11G` (already excluded by our filter)
      - `Engine/Content` ≈ `6.6G`
      - `Engine/Extras` ≈ `5.1G` (includes Epic toolchain)
  - Implication:
    - The current filter already drops `Engine/Intermediate`, `Engine/DerivedDataCache`, `Engine/Saved`, `.git`, and `LocalBuilds`, but the remaining “must-have” parts are still huge.
    - Most promising further reduction is likely excluding **built artifacts** under `Engine/Binaries/*` (while keeping `Engine/Binaries/ThirdParty/DotNet`), but we must confirm BuildGraph doesn’t depend on other parts of `Engine/Binaries`.

- ✅ 2.1.2(B) BuildGraph output dir control confirmed (from UE `InstalledEngineBuild.xml`):
  - File inspected (read-only): `~/projects/dev/cpp/UnrealEngine/Engine/Build/InstalledEngineBuild.xml`
  - Key lines:
    - `<Option Name="BuiltDirectory" DefaultValue="$(RootDir)/LocalBuilds/Engine" ... />`
  - Conclusion:
    - We can avoid writing `LocalBuilds/` inside the UE source tree by passing a BuildGraph `-set:BuiltDirectory=/some/writable/path` (or equivalent) when running `RunUAT.sh BuildGraph ...`.
    - This makes a flake `app` approach (run BuildGraph in FHS, output elsewhere) the preferred practical path for 2.1.2.
  - Extra detail (confirmed by reading the XML near the option definition):
    - `LocalInstalledDirLinux` is derived from `BuiltDirectory` as `$(BuiltDirectory)/Linux`.
    - The XML sets `SavedOutput` to `$(RootDir)/Engine/Saved`, but this is likely also overridable via `-set:SavedOutput=/some/writable/path` if we want *zero* writes under the UE source tree during the installed-build build.

- ✅ 2.1.2(C) Added flake app to run BuildGraph outside the Nix builder (fast validation only so far):
  - File changed: `pkgs/unreal/flake.nix`
  - First attempt failed: `pkgs.writeShellApplication` runs ShellCheck and rejected our `-lc '...'` quoting (SC2016).
  - Fix: switched to `pkgs.writeShellScriptBin` and passed `WITH_DDC` via env instead of quote-splicing.
  - Validation (fast):
    - `cd pkgs/unreal && NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix run path:.#unreal-build-installed -- --help`
    - Result: prints usage successfully.

- ✅ 2.1.2(D) Switched `unreal-engine-installed` to package an *already-built* installed-build tree (instead of compiling inside Nix):
  - File changed: `pkgs/unreal/unreal.nix`
  - New behavior:
    - Expects a BuildGraph output dir (default: `$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux`), overridable via `UE_INSTALLED_DIR` or `UE_BUILTDIR`.
    - Copies that tree into `$out` and adds `$out/bin/UnrealEditor` wrapper (runs inside `ue5-fhs`).
  - Validation (fast failure when the installed build is missing):
    - `cd pkgs/unreal && NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix build path:.#unreal-engine-installed --impure -L`
    - Result: fails with a clear message pointing to `nix run path:.#unreal-build-installed` to produce the missing tree.

- 🚧 2.1.2(C) medium validation (start UAT for ~60s, then stop):
  - First attempt mistake: `timeout 60s UE_SRC=... nix run ...` (wrong syntax) → `timeout: failed to run command 'UE_SRC=...': No such file or directory`
  - Corrected command:
    - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' timeout 60s nix run path:.#unreal-build-installed -- --with-ddc=false`
  - Observed:
    - UAT starts, bundled dotnet is used, and compilation begins (e.g. `****** [2/9] Compile UnrealEditor Linux`).
    - BuildGraph rejects our attempt to override `SavedOutput`:
      - `Unknown argument 'SavedOutput' for .../InstalledEngineBuild.xml`
      - The XML only accepts `BuiltDirectory` (and many others), not `SavedOutput`.
    - Timeout stops the run after 60s (exit code 124).
  - Repo safety check:
    - `cd ~/projects/dev/cpp/UnrealEngine && git status --porcelain` → empty (no tracked changes).
  - Next fix:
    - Remove `-set:SavedOutput=...` from the `unreal-build-installed` app (keep `BuiltDirectory`).

- ✅ 2.1.2(C) fixed: removed invalid `SavedOutput` override and re-validated startup:
  - File changed: `pkgs/unreal/flake.nix` (removed `--saved-output` + `UE_SAVED_OUTPUT` and dropped `-set:SavedOutput=...`).
  - Validation:
    - `cd pkgs/unreal && nix run path:.#unreal-build-installed -- --help` shows updated usage and warns that the XML does not accept `SavedOutput` overrides.
    - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' timeout 30s nix run path:.#unreal-build-installed -- --with-ddc=false`
      - Result: BuildGraph starts and begins compilation without the previous `Unknown argument 'SavedOutput'` error (timeout still stops it after 30s; exit code 124).

- 🚧 2.1.2(C) running full installed-build BuildGraph (long-running):
  - Command:
    - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix run path:.#unreal-build-installed -- --with-ddc=false`
  - Status (early):
    - BuildGraph reached `****** [2/9] Compile UnrealEditor Linux`.
    - Using bundled dotnet + Epic toolchain (`v26_clang-20.1.8-rockylinux8`).
    - Logs observed writing under:
      - `~/projects/dev/cpp/UnrealEngine/Engine/Saved/BuildGraph/...`
      - `~/Library/Logs/Unreal Engine/LocalBuildLogs/...`
    - Update: compilation has started (UBA local executor), e.g. `Building UnrealEditor and LiveLinkHub...` and `Compile Module.Launch.cpp`.
    - Update: `Compile UnrealEditor Linux` finished with `Result: Succeeded`; BuildGraph moved on to the next block (now compiling UnrealGame Linux with thousands of actions, e.g. `[...] /3248`).
  - Success criteria:
    - `~/ .cache/unreal-engine/LocalBuilds/Engine/Linux/Engine/Binaries/Linux/UnrealEditor` exists (installed build output).
  - Current: `~/ .cache/unreal-engine/LocalBuilds/Engine` exists but is still empty (build is still in compile/stage steps; no output copied yet).

- 🚧 2.1.2(C) progress check (BuildGraph still running):
  - Commands:
    - `ls -la ~/.cache/unreal-engine/LocalBuilds/Engine`
    - `pgrep -af 'RunUAT\\.sh|BuildGraph|UnrealBuildTool|AutomationTool|DotNET'`
    - `tail -n 30 ~/Library/Logs/Unreal\\ Engine/LocalBuildLogs/Log.txt`
  - Results:
    - `~/.cache/unreal-engine/LocalBuilds/Engine` currently exists but has no `Linux/` subdir yet (output is not staged/copied yet).
    - Processes confirm the BuildGraph run is still active, e.g.:
      - `... RunUAT.sh BuildGraph ... -set:BuiltDirectory=/home/vitalyr/.cache/unreal-engine/LocalBuilds/Engine ...`
      - `... dotnet AutomationTool.dll BuildGraph ...`
      - `... dotnet UnrealBuildTool.dll -Target=UnrealGame Linux Shipping ...`
    - Log tail indicates it is still compiling UnrealGame, e.g. `[...] [744/3248] Compile ...`

- ❌ 2.1.2(C) BuildGraph run ended unexpectedly with no installed-build output:
  - Observed after waiting:
    - `pgrep -af 'RunUAT\\.sh|BuildGraph|UnrealBuildTool|AutomationTool\\.dll'` → no BuildGraph-related processes.
    - `~/.cache/unreal-engine/LocalBuilds/Engine` is still empty (no `Linux/` output):
      - `find ~/.cache/unreal-engine/LocalBuilds/Engine -maxdepth 3 | head` → only the directory itself.
    - Logs appear to stop mid-compilation (no final `Result: Succeeded/Failed` summary in `Log.txt`):
      - `tail -n 1 ~/Library/Logs/Unreal\\ Engine/LocalBuildLogs/Log.txt` → `[...] [838/3248] Compile ...`
      - `tail -n 1 ~/Library/Logs/Unreal\\ Engine/LocalBuildLogs/UBA-UnrealGame-Linux-Shipping.txt` → `[...] [839/3248] Compile ...`
  - Preliminary diagnosis:
    - The run likely terminated abruptly (manual interrupt, or external kill/OOM). No compile errors were found by grepping for common patterns (`fatal error`, `ld.lld: error`, `Result: Failed`, etc).
    - Since `dmesg` is not readable as an unprivileged user here, we cannot confirm OOM kills from kernel logs.
  - Next action (retry with full observability):
    - Re-run the BuildGraph command via the flake app in a monitored session, so we capture the final exit code and last stderr lines:
      - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine UE_BUILTDIR=~/.cache/unreal-engine/LocalBuilds/Engine nix run path:.#unreal-build-installed -- --with-ddc=false`
    - Success criteria unchanged: `~/.cache/unreal-engine/LocalBuilds/Engine/Linux/Engine/Binaries/Linux/UnrealEditor` exists.

- 🚧 2.1.2(C) retry started (monitored):
  - Command:
    - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine UE_BUILTDIR=~/.cache/unreal-engine/LocalBuilds/Engine NIX_CONFIG='substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' nix run path:.#unreal-build-installed -- --with-ddc=false`
  - Early output:
    - UAT starts successfully, bundled dotnet is detected, and BuildGraph begins `****** [1/9] Update Version Files` then `****** [2/9] Compile UnrealEditor Linux`.
    - Toolchain confirmed: `v26_clang-20.1.8-rockylinux8`.
  - Status: running (waiting for it to complete and to populate `~/.cache/unreal-engine/LocalBuilds/Engine/Linux`).

- ⚠️ 2.1.2(C) retry revealed unexpected extra work: BuildGraph started building `LinuxArm64` after finishing x86_64:
  - Observed in the monitored output:
    - `Result: Succeeded` for the `UnrealGame-Linux-Shipping` build (x86_64), then BuildGraph continued with `UnrealGame-LinuxArm64-*` actions (`[.../2767] ... [aarch64] ...`).
  - Diagnosis (from `Engine/Build/InstalledEngineBuild.xml`):
    - `WithLinuxArm64` exists as an option and defaults to `true` for Linux hosts unless overridden.
    - Since we only need an x86_64 installed build on this machine, building LinuxArm64 is wasted time and may fail due to cross constraints.
  - Action:
    - Interrupted the running BuildGraph retry with `^C`.
    - Updated `pkgs/unreal/flake.nix` to force `-set:WithLinuxArm64=false` in `unreal-build-installed`.
  - Next:
    - Re-run `nix run path:.#unreal-build-installed -- --with-ddc=false` and wait for BuildGraph to proceed past compilation into the staging steps that populate `UE_BUILTDIR/Linux`.

- 🚧 2.1.2(C) retry (WithLinuxArm64 disabled):
  - Command:
    - `cd pkgs/unreal && env UE_SRC=~/projects/dev/cpp/UnrealEngine UE_BUILTDIR=~/.cache/unreal-engine/LocalBuilds/Engine nix run path:.#unreal-build-installed -- --with-ddc=false`
  - Observed:
    - BuildGraph command line now includes `-set:WithLinuxArm64=false`.
    - The graph now reports `****** [1/8] ...` (one fewer step vs the previous run that attempted LinuxArm64).
  - Status: running.

- ✅ 2.1.2(C) BuildGraph installed-build completed successfully (Linux only):
  - Key output:
    - `****** [8/8] Make Installed Build Linux`
    - `BUILD SUCCESSFUL`
    - `AutomationTool exiting with ExitCode=0 (Success)`
  - Success criteria met:
    - `~/.cache/unreal-engine/LocalBuilds/Engine/Linux/Engine/Binaries/Linux/UnrealEditor` exists.
  - Next:
    - Package the installed build into the Nix store via `nix build path:.#unreal-engine-installed --impure -L`, then run `./result/bin/UnrealEditor -nullrhi -help` to verify it starts from the packaged tree.

- ⚠️ 2.1.2(D) Packaging attempt 1 (copying the whole installed build) was too slow / noisy due to fixup scanning:
  - Command:
    - `cd pkgs/unreal && UE_BUILTDIR=~/.cache/unreal-engine/LocalBuilds/Engine nix build path:.#unreal-engine-installed --impure -L`
  - Observed:
    - `builtins.path` imported the installed build into the store (≈47G store path `...-UnrealEngine-installed-linux`).
    - The derivation then entered `fixupPhase` and attempted to `patchelf` many non-dynamic files (notably `.o` objects under `Engine/Plugins/*/Intermediate/.../*.o`), producing tons of messages like:
      - `patchelf: wrong ELF type`
  - Action:
    - Interrupted the build (`^C`) to avoid wasting time on `fixupPhase` work that we don't need for a prebuilt binary tree.
    - Updated `pkgs/unreal/unreal.nix` to package the installed build via `pkgs.symlinkJoin` (symlink tree) instead of copying it, so Nix fixups won’t traverse/patch the full UE tree.
  - Next:
    - Retry `nix build path:.#unreal-engine-installed --impure -L` (should be fast now) and verify runtime.

- ⚠️ 2.1.2(E) Packaging attempt 2 still triggers a large re-import from disk:
  - Observed:
    - Even with the `symlinkJoin` approach, `installedSrc = builtins.path { path = $UE_BUILTDIR/Linux; ... }` causes Nix to (re)materialize a large `/nix/store/tmp-*` while importing the local installed-build directory.
  - Mitigation:
    - Added `UE_INSTALLED_STORE_PATH` support in `pkgs/unreal/unreal.nix`:
      - If set to an existing `/nix/store/...-UnrealEngine-installed-linux` path, we skip importing from disk and reuse the already-imported store path.
  - Next:
    - Determine the store path (from the previous import we observed `...-UnrealEngine-installed-linux` exists), then run:
      - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/<hash>-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L`

- ✅ 2.1.2(F) Packaged installed build successfully (fast via `UE_INSTALLED_STORE_PATH`) and verified it runs:
  - Build:
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L`
  - Run (headless, bounded):
    - `cd pkgs/unreal && timeout 120s ./result/bin/UnrealEditor -nullrhi -help 2>&1 | rg --text -n 'Engine is initialized|FEngineLoop::Init\\(\\)|Running engine' | tail -n 50`
  - Success signal:
    - `LogInit: Display: Engine is initialized. Leaving FEngineLoop::Init()`

- ✅ 2.1.2(G) Ported PKGBUILD desktop + icon bits into `unreal-engine-installed`:
  - Files added:
    - `pkgs/unreal/com.unrealengine.UE5Editor.desktop` (Exec uses `ue5editor %U`)
    - `pkgs/unreal/ue5editor.svg`
  - File changed:
    - `pkgs/unreal/unreal.nix` (packages desktop + icon via `symlinkJoin`)
  - Build (fast, using the already-imported installed tree):
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L`
  - Validation:
    - `ls -la result/share/applications result/share/pixmaps` shows:
      - `result/share/applications/com.unrealengine.UE5Editor.desktop`
      - `result/share/pixmaps/ue5editor.svg`
    - `timeout 120s ./result/bin/UnrealEditor -nullrhi -help` still reaches:
      - `Engine is initialized. Leaving FEngineLoop::Init()`

- ✅ 2.1.2(H) Made `unreal-engine-installed` evaluatable even when the installed build is missing (fail at build time, not eval time):
  - File changed:
    - `pkgs/unreal/unreal.nix` (switch `installedSrc` → `installedSrcOrNull` + a failing `runCommandNoCC` when missing)
  - Validation (expected failure with a clear message):
    - `cd pkgs/unreal && UE_INSTALLED_DIR=/does/not/exist nix build path:.#unreal-engine-installed --impure -L`
    - Result: build fails quickly and prints instructions to run `nix run path:.#unreal-build-installed`.

- ✅ 2.1.2(I) Ported PKGBUILD wrapper-name conventions (symlinks) + root safety:
  - File changed:
    - `pkgs/unreal/unreal.nix`
  - Changes:
    - Both local + installed wrappers now refuse to run as root.
    - Added symlinks: `ue5`, `UE5`, `unreal-engine-5` → `ue5editor` → `UnrealEditor`.
 - Validation:
    - `cd pkgs/unreal && nix build path:.#unreal-engine --impure -L`
    - `cd pkgs/unreal && ls -la result/bin` shows `ue5`, `UE5`, `unreal-engine-5` symlinks.

### 2026-01-19 (Phase 2 cleanup / reproducibility)

**Context:** Earlier we pinned `inputs.nixpkgs.url` to a local `path:/nix/store/.../nixos` snapshot due to repeated GitHub TLS EOF errors. Bandwidth is now ~2 MiB/s, so we should switch back to a reproducible remote pin.

- 🚧 2.4 Switch flake `nixpkgs` input back to GitHub and refresh `flake.lock`.
  - Files to modify:
    - `pkgs/unreal/flake.nix`
    - `pkgs/unreal/flake.lock` (via `nix flake lock`)
  - Planned commands:
    - `cd pkgs/unreal && nix flake lock --recreate-lock-file --refresh`
    - `cd pkgs/unreal && nix flake metadata --refresh`
    - `cd pkgs/unreal && nix run path:.#unreal-fhs -- -lc 'echo OK; test -x /bin/bash && echo /bin/bash=OK'`
    - `cd pkgs/unreal && nix build path:.#unreal-engine --impure -L`
    - (optional, if `UE_INSTALLED_STORE_PATH` is available) `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/<hash>-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L`
  - Success criteria:
    - `flake.lock` no longer uses `"type": "path"` for `nixpkgs`
    - `nix run .#unreal-fhs` still provides `/bin/bash`
    - wrapper packages still build

- ✅ 2.4 Completed: switched `nixpkgs` input back to GitHub and re-validated the flake.
  - Files changed:
    - `pkgs/unreal/flake.nix` (`inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";`)
    - `pkgs/unreal/flake.lock` now pins:
      - `rev = ac62194c3917d5f474c1a844b6fd6da2db95077d` (2026-01-02)
  - Lock refresh:
    - `cd pkgs/unreal && nix flake lock --recreate-lock-file --refresh`
    - Output key line:
      - `Updated input 'nixpkgs': ... → 'github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d ...'`
  - Metadata sanity:
    - `cd pkgs/unreal && nix flake metadata --refresh`
    - Confirms `Inputs: nixpkgs: github:NixOS/nixpkgs/ac62194c...`
  - FHS env sanity:
    - `cd pkgs/unreal && nix run path:.#unreal-fhs -- -lc 'echo OK; test -x /bin/bash && echo /bin/bash=OK'`
    - Result:
      - `OK`
      - `/bin/bash=OK`
  - Wrapper build sanity:
    - `cd pkgs/unreal && nix build path:.#unreal-engine --impure -L` (succeeds)
  - Installed wrapper build sanity (reusing previous store import):
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L`
  - Runtime sanity:
    - `cd pkgs/unreal && timeout 120s ./result/bin/UnrealEditor -nullrhi -help`
    - Success signal:
      - `LogInit: Display: Engine is initialized. Leaving FEngineLoop::Init()`

- 🚧 2.5 Add a flake app to “import + package” the installed build in one command.
  - Motivation:
    - `unreal-engine-installed` can package a BuildGraph installed-build tree, but the first import into the store is slow (tens of GB).
    - We already support `UE_INSTALLED_STORE_PATH` to skip re-imports; we now want an app that creates this store path automatically and then runs `nix build`.
  - Files to modify:
    - `pkgs/unreal/flake.nix` (add `unreal-package-installed` script + `apps` entry)
  - Planned commands (validation):
    - `cd pkgs/unreal && nix run path:.#unreal-package-installed -- --help`
    - Fast-path (reuse existing import):
      - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix run path:.#unreal-package-installed -- --out-link result-installed`
      - `cd pkgs/unreal && timeout 120s ./result-installed/bin/UnrealEditor -nullrhi -help`
    - Real-path (one-time import; slow; optional):
      - `cd pkgs/unreal && UE_INSTALLED_DIR=$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux nix run path:.#unreal-package-installed -- --out-link result-installed`
  - Success criteria:
    - `nix run ...#unreal-package-installed` prints the chosen/added `UE_INSTALLED_STORE_PATH` and produces the requested out-link.
    - The produced `result-installed/bin/UnrealEditor` starts (headless) to `Engine is initialized...`.

- ✅ 2.5 Completed: added `unreal-package-installed` flake app and validated end-to-end.
  - File changed:
    - `pkgs/unreal/flake.nix` (adds `unreal-package-installed` script + `packages.unreal-package-installed` + `apps.unreal-package-installed`)
  - Validation:
    - Help:
      - `cd pkgs/unreal && nix run path:.#unreal-package-installed -- --help` → prints usage.
    - ⚠️ Initial CLI mismatch:
      - Attempted `--out-link result-installed` but the script only accepted `--out-link=...` and failed with `Unknown argument: --out-link`.
      - Fix: updated the script to accept both `--out-link NAME` and `--out-link=NAME` (same for `--installed-dir`).
    - Fast-path packaging (reuse existing store import):
      - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix run path:.#unreal-package-installed -- --out-link result-installed`
      - Script output includes:
        - `Reusing UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux`
    - Runtime sanity:
      - `cd pkgs/unreal && timeout 120s ./result-installed/bin/UnrealEditor -nullrhi -help`
      - Success signal:
        - `LogInit: Display: Engine is initialized. Leaving FEngineLoop::Init()`

- 🚧 2.6 Add a flake app for running `Setup.sh` in the FHS environment (non-interactive).
  - Motivation:
    - Users frequently hit `/bin/bash: bad interpreter` on NixOS when running `./Setup.sh` directly.
    - We already have `unreal-fhs`; this app provides a single-purpose wrapper with a consistent `UE_SRC` interface.
  - Files to modify:
    - `pkgs/unreal/flake.nix` (add `unreal-setup` script + `apps` entry)
  - Planned commands (validation):
    - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-setup -- --help`
    - (quick start check; does not wait for downloads) `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine timeout 5s nix run path:.#unreal-setup -- --force || true`
  - Success criteria:
    - The wrapper runs inside FHS (no `/bin/bash` interpreter errors) and reaches `Setup.sh` help/early output.

- ✅ 2.6 Completed: added `unreal-setup` flake app and validated it starts `Setup.sh` under FHS.
  - File changed:
    - `pkgs/unreal/flake.nix` (adds `unreal-setup` script + `packages.unreal-setup` + `apps.unreal-setup`)
  - Validation:
    - Wrapper usage:
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-setup -- --help`
      - Prints wrapper usage (and avoids running `Setup.sh` for `--help`, since `Setup.sh --help` still performs work).
    - Start check (bounded):
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine timeout 5s nix run path:.#unreal-setup -- --force || true`
      - Observed early output (proves `/bin/bash` is available inside FHS):
        - `Registering git hooks... (this will override existing ones!)`
        - `Checking dependencies...`

- 🚧 2.7 Add a flake app for running `GenerateProjectFiles.sh` in the FHS environment.
  - Motivation:
    - Completes the Phase 1 “Setup → GenerateProjectFiles → Build” workflow without an interactive FHS shell.
  - Files to modify:
    - `pkgs/unreal/flake.nix` (add `unreal-generate-project-files` script + `apps` entry)
  - Planned commands (validation):
    - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-generate-project-files -- --help`
    - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-generate-project-files`
  - Success criteria:
    - The wrapper runs inside FHS and `GenerateProjectFiles.sh` completes successfully (logs contain `Result: Succeeded`).

- ✅ 2.7 Completed: added `unreal-generate-project-files` app and validated `GenerateProjectFiles.sh` succeeds under FHS.
  - File changed:
    - `pkgs/unreal/flake.nix` (adds `unreal-generate-project-files` script + `packages` + `apps` entry)
  - Validation:
    - Wrapper usage:
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-generate-project-files -- --help`
    - Run:
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-generate-project-files`
    - Success signal:
      - `Result: Succeeded`
      - `Total execution time: 30.25 seconds`

- 🚧 2.8 Add a flake app for running `Engine/Build/BatchFiles/Linux/Build.sh` in the FHS environment.
  - Motivation:
    - Completes the Phase 1 “Setup → GenerateProjectFiles → Build” workflow as flake apps.
  - Files to modify:
    - `pkgs/unreal/flake.nix` (add `unreal-build` script + `apps` entry)
  - Planned commands (validation):
    - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- --help`
    - Build a small/fast target (should be incremental on an already-built tree):
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- ShaderCompileWorker Linux Development -Progress`
  - Success criteria:
    - The wrapper runs inside FHS (no interpreter errors) and the build ends with `Result: Succeeded`.

- ✅ 2.8 Completed: added `unreal-build` app and validated it can build a target under FHS.
  - File changed:
    - `pkgs/unreal/flake.nix` (adds `unreal-build` script + `packages` + `apps` entry)
  - Validation:
    - Wrapper usage:
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- --help`
    - Build (incremental):
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- ShaderCompileWorker Linux Development -Progress`
    - Success signal:
      - `Result: Succeeded`
      - `Total execution time: 3.57 seconds`

- 🚧 2.9 Add a flake app to run the BuildGraph installed build directly from `UE_INSTALLED_DIR` (no store packaging).
  - Motivation:
    - Lets us validate the installed build (`LocalBuilds/Engine/Linux/...`) *before* importing tens of GB into `/nix/store`.
  - Files to modify:
    - `pkgs/unreal/flake.nix` (add `unreal-editor-installed-dir` script + `apps` entry)
  - Planned commands (validation):
    - `cd pkgs/unreal && nix run path:.#unreal-editor-installed-dir -- --help`
    - `cd pkgs/unreal && UE_INSTALLED_DIR=$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux timeout 120s nix run path:.#unreal-editor-installed-dir -- -nullrhi -help 2>&1 | rg --text -n 'Engine is initialized|FEngineLoop::Init\\(\\)|Running engine' | tail -n 50`
  - Success criteria:
    - Wrapper runs inside FHS and reaches `Engine is initialized...` from the installed build dir.

- 🚧 2.9 Validation (initial):
  - Help:
    - `cd pkgs/unreal && nix run path:.#unreal-editor-installed-dir -- --help` → OK.
  - Run attempt:
    - `cd pkgs/unreal && UE_INSTALLED_DIR=$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux timeout 120s nix run path:.#unreal-editor-installed-dir -- -nullrhi -help 2>&1 | rg --text -n 'Engine is initialized|FEngineLoop::Init\\(\\)|Running engine' | tail -n 50`
  - Observed:
    - Only saw `LogInit: Display: Running engine without a game` within the filtered output; did **not** see `Engine is initialized...` yet.
  - Next:
    - Re-run capturing full output to a file, then grep for `Engine is initialized` to distinguish:
      - slow startup vs no stdout vs early failure/timeout.

- ✅ 2.9 Completed: added `unreal-editor-installed-dir` and validated it runs the installed build from `UE_INSTALLED_DIR`.
  - File changed:
    - `pkgs/unreal/flake.nix` (adds `unreal-editor-installed-dir` script + `packages` + `apps` entry)
  - Validation:
    - Help:
      - `cd pkgs/unreal && nix run path:.#unreal-editor-installed-dir -- --help` → OK.
    - Startup timing note:
      - `-nullrhi -help` from the *local installed build dir* was very slow in this environment and did not reach `Engine is initialized...` within 120s or 300s (timeouts hit).
    - Fast sanity check (exits successfully):
      - `cd pkgs/unreal && UE_INSTALLED_DIR=$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux timeout 30s nix run path:.#unreal-editor-installed-dir -- -version`
      - Result: exits `0` (proves the binary can start under FHS from `UE_INSTALLED_DIR`).
  - Note:
    - For a quick “Engine is initialized...” probe we still recommend the packaged wrapper:
      - `cd pkgs/unreal && timeout 120s ./result/bin/UnrealEditor -nullrhi -help`

## Quickstart (current recommended commands)

All commands are executed from `~/projects/dev/nix/nix-hanse/pkgs/unreal` and assume:
- UE source tree: `~/projects/dev/cpp/UnrealEngine`
- We do **not** patch UE sources; we only run Epic scripts/builds.

### Phase 1 (source build in-place, under FHS)

1) Setup (downloads GitDependencies, installs bundled toolchain):
- `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-setup -- --force`
  - Note: by default the wrapper avoids overriding `.git/hooks/*`. Set `UE_SETUP_ALLOW_GIT_HOOKS=1` to restore `Setup.sh`’s hook registration.

2) Generate project files:
- `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-generate-project-files`

3) Build required targets:
- `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- UnrealEditor Linux Development -Progress`
- `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- ShaderCompileWorker Linux Development -Progress`

4) Run editor (via wrapper + FHS):
- `timeout 120s nix run path:.#unreal-editor -- -nullrhi -help`

### Phase 2 (BuildGraph “installed build” + package)

1) BuildGraph installed build (writes to user dir, not UE tree):
- `UE_SRC=~/projects/dev/cpp/UnrealEngine UE_BUILTDIR=$HOME/.cache/unreal-engine/LocalBuilds/Engine nix run path:.#unreal-build-installed -- --with-ddc=false`

2) (Optional) Run installed build directly from disk (no store import):
- `UE_INSTALLED_DIR=$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux nix run path:.#unreal-editor-installed-dir -- -version`

3) Package installed build into the Nix store (one-time import + wrapper):
- `nix run path:.#unreal-package-installed -- --out-link result-installed`
  - Note: the script caches the store path under `~/.cache/unreal-engine/UE_INSTALLED_STORE_PATH` and will reuse it automatically on subsequent runs.
  - Optional override:
    - `UE_INSTALLED_STORE_PATH=/nix/store/<hash>-UnrealEngine-installed-linux nix run path:.#unreal-package-installed -- --out-link result-installed`

4) Run the packaged editor wrapper:
- `timeout 120s ./result-installed/bin/UnrealEditor -nullrhi -help`

### Smoothly running the packaged installed editor (interactive)

Goal: run the *packaged installed build* (`result-installed`) without fighting `/nix/store` read-only writes or injecting SIGTERM via `timeout`.

One-time (or after code changes) build the wrapper package:

- Preferred (reuses cached installed-build store path if available):
  - `cd pkgs/unreal && nix run path:.#unreal-package-installed -- --out-link result-installed`

- If you already know the installed-build store path:
  - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/<hash>-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`

Run the editor (full UI):

- Basic:
  - `cd pkgs/unreal && ./result-installed/bin/UnrealEditor`
- With logs in terminal:
  - `cd pkgs/unreal && ./result-installed/bin/UnrealEditor -stdout -FullStdOutLogOutput -log`
- Open a project:
  - `cd pkgs/unreal && ./result-installed/bin/UnrealEditor /abs/path/to/MyProject/MyProject.uproject -stdout -FullStdOutLogOutput -log`

Notes:
- Do **not** wrap normal interactive runs in `timeout` (it sends SIGTERM by default).
- For “run for N seconds then stop” debugging, use SIGINT instead:
  - `cd pkgs/unreal && timeout -s INT 120s ./result-installed/bin/UnrealEditor -stdout -FullStdOutLogOutput -log`
- The wrapper creates a writable overlay under:
  - `$XDG_CACHE_HOME/unreal-engine/store-overlay/<store-basename>/`
  (fallback: `~/.cache/unreal-engine/store-overlay/...`)

- 🚧 2.10 Make `unreal-setup` not override UE git hooks by default.
  - Motivation:
    - `~/projects/dev/cpp/UnrealEngine/Setup.sh` prints `Registering git hooks... (this will override existing ones!)` and overwrites `.git/hooks/post-{checkout,merge}`.
    - This is an unnecessary side-effect for packaging/build workflows.
  - Files to modify:
    - `pkgs/unreal/flake.nix` (update `unreal-setup` script)
  - Planned change:
    - Default: set `GIT_DIR=/dev/null` when invoking `Setup.sh` so the `-d "$GIT_DIR/hooks"` check fails and no hooks are written.
    - Opt-in to hook registration via env var: `UE_SETUP_ALLOW_GIT_HOOKS=1`.
  - Planned commands (validation):
    - Capture hook checksums before:
      - `UE_SRC=~/projects/dev/cpp/UnrealEngine bash -lc 'for f in .git/hooks/post-checkout .git/hooks/post-merge; do echo \"== $f\"; test -e \"$UE_SRC/$f\" && sha256sum \"$UE_SRC/$f\" && stat -c \"mtime=%y size=%s\" \"$UE_SRC/$f\" || echo missing; done'`
    - Run setup (bounded) and confirm it does **not** print `Registering git hooks...`:
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine timeout 5s nix run path:.#unreal-setup -- --force || true`
    - Capture hook checksums after (must match “before”):
      - same as above
  - Success criteria:
    - Default wrapper run does not overwrite `.git/hooks/*` and does not print the warning line.

- ✅ 2.10 Completed: `unreal-setup` no longer overwrites UE git hooks by default.
  - File changed:
    - `pkgs/unreal/flake.nix` (wraps `Setup.sh` with `GIT_DIR=/dev/null` unless `UE_SETUP_ALLOW_GIT_HOOKS=1`)
  - Validation:
    - Hook checksums before:
      - `.git/hooks/post-checkout` sha256 `f0f5a3dd...` mtime `2026-01-19 13:37:28 +0800`
      - `.git/hooks/post-merge`   sha256 `f0f5a3dd...` mtime `2026-01-19 13:37:28 +0800`
    - Run (bounded):
      - `cd pkgs/unreal && UE_SRC=~/projects/dev/cpp/UnrealEngine timeout 5s nix run path:.#unreal-setup -- --force`
      - Output does **not** contain: `Registering git hooks...`
    - Hook checksums after: unchanged (same sha256 + mtime).
  - Opt-in:
    - Set `UE_SETUP_ALLOW_GIT_HOOKS=1` if you explicitly want `Setup.sh` to register hooks.

- 🚧 2.11 Cache `UE_INSTALLED_STORE_PATH` automatically in `unreal-package-installed`.
  - Motivation:
    - Users currently need to copy/paste a huge `/nix/store/...-UnrealEngine-installed-linux` path into `UE_INSTALLED_STORE_PATH` to avoid re-importing ~50G from disk.
    - We can make this ergonomic by writing/reading a cache file under `$XDG_CACHE_HOME` (or `~/.cache`).
  - Files to modify:
    - `pkgs/unreal/flake.nix` (update `unreal-package-installed` script)
  - Planned behavior:
    - Cache file: `$XDG_CACHE_HOME/unreal-engine/UE_INSTALLED_STORE_PATH` (fallback: `~/.cache/unreal-engine/UE_INSTALLED_STORE_PATH`)
    - If `UE_INSTALLED_STORE_PATH` env var is **not** set and the cache file exists and points to an existing store path, reuse it.
    - After selecting `store_path` (from env, cache, or `nix store add-path`), write it back to the cache file.
  - Planned commands (validation):
    - Seed cache via env var fast path:
      - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix run path:.#unreal-package-installed -- --out-link result-installed`
    - Confirm cache file exists:
      - `test -f ~/.cache/unreal-engine/UE_INSTALLED_STORE_PATH && cat ~/.cache/unreal-engine/UE_INSTALLED_STORE_PATH`
    - Run again *without* `UE_INSTALLED_STORE_PATH` and ensure it still reuses the cached path (no re-import):
      - `cd pkgs/unreal && nix run path:.#unreal-package-installed -- --out-link result-installed`
  - Success criteria:
    - Second run reuses cached store path and is fast.

- ✅ 2.11 Completed: `unreal-package-installed` now caches and reuses `UE_INSTALLED_STORE_PATH`.
  - File changed:
    - `pkgs/unreal/flake.nix` (`unreal-package-installed` reads/writes `$XDG_CACHE_HOME/unreal-engine/UE_INSTALLED_STORE_PATH`)
  - Validation:
    - Seeded cache via env var:
      - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix run path:.#unreal-package-installed -- --out-link result-installed`
      - Script prints: `Cached UE_INSTALLED_STORE_PATH in: /home/vitalyr/.cache/unreal-engine/UE_INSTALLED_STORE_PATH`
    - Cache file exists and contains the store path:
      - `cat ~/.cache/unreal-engine/UE_INSTALLED_STORE_PATH` → `/nix/store/h9bc3r5w...-UnrealEngine-installed-linux`
    - Second run without the env var reuses the cache (fast; no re-import):
      - `cd pkgs/unreal && env -u UE_INSTALLED_STORE_PATH nix run path:.#unreal-package-installed -- --out-link result-installed`
      - Script prints: `Reusing UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5w...`

- 🚧 2.12 Make `unreal-engine` wrapper package evaluatable without a local UE source checkout.
  - Motivation:
    - `pkgs/unreal/unreal.nix` currently throws at evaluation time if `UE_SRC` does not exist, which breaks `nix flake show` / `nix build` in environments that don’t have the UE checkout.
    - We want a “buildable wrapper that fails at runtime with a clear message” (same philosophy as `unreal-engine-installed`).
  - Files to modify:
    - `pkgs/unreal/unreal.nix` (remove eval-time `builtins.pathExists` throw; keep runtime checks in wrapper script)
  - Planned commands (validation):
    - `cd pkgs/unreal && UE_SRC=/does/not/exist nix build path:.#unreal-engine --impure -L` (should build; no eval error)
    - `cd pkgs/unreal && ./result/bin/UnrealEditor -help` (should fail quickly with a clear message about missing UE_SRC)
  - Success criteria:
    - No eval-time exception; wrapper handles missing path at runtime.

- ✅ 2.12 Completed: `unreal-engine` no longer throws at eval time when `UE_SRC` is missing.
  - File changed:
    - `pkgs/unreal/unreal.nix` (removed `builtins.pathExists` throw; added runtime directory check in wrapper script)
  - Validation:
    - Build with a missing UE_SRC no longer fails at evaluation:
      - `cd pkgs/unreal && UE_SRC=/does/not/exist nix build path:.#unreal-engine --impure -L` → succeeds.
    - Runtime failure is explicit and non-zero:
      - `cd pkgs/unreal && ./result/bin/UnrealEditor -help`
      - Output:
        - `ERROR: UE source dir not found: /does/not/exist`
      - Exit: `1`
    - Flake app still works with the default UE_SRC:
      - `cd pkgs/unreal && timeout 120s nix run path:.#unreal-editor -- -nullrhi -help`
      - Success signal:
        - `LogInit: Display: Engine is initialized. Leaving FEngineLoop::Init()`

## Current status (2026-01-19)

- Phase 1: ✅ UE source build works on NixOS under the flake-provided FHS env; editor can reach `Engine is initialized...`.
- Phase 2: ✅ Flake provides `apps` + `packages` for:
  - FHS shell (`unreal-fhs`)
  - Setup / GPF / Build.sh (`unreal-setup`, `unreal-generate-project-files`, `unreal-build`)
  - BuildGraph installed build (`unreal-build-installed`)
  - Packaging installed build into a Nix output (`unreal-package-installed`, with cached `UE_INSTALLED_STORE_PATH`)
  - Local and installed editor wrappers (`unreal-editor`, `unreal-editor-installed`, `unreal-editor-installed-dir`)

## Optional backlog (not required for current goal)

- “Pure” Nix build of UE inside a derivation (likely impractical due to UE size + license + sandbox networking; requires more design).
- More wrapper UX parity with the AUR `unreal-engine-5.sh` (only if needed for real desktop integration).

- 🚧 2.13 Add `unreal-engine-5.sh` wrapper name compatibility (AUR parity).
  - Motivation:
    - AUR PKGBUILD installs `/usr/bin/unreal-engine-5.sh`; adding the same name improves compatibility with scripts/desktop entries.
  - Files to modify:
    - `pkgs/unreal/unreal.nix` (add `unreal-engine-5.sh` symlink for both local + installed wrappers)
  - Planned commands (validation):
    - `cd pkgs/unreal && nix build path:.#unreal-engine --impure -L && ls -la result/bin | rg -n \"unreal-engine-5\\.sh\"`
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L && ls -la result/bin | rg -n \"unreal-engine-5\\.sh\"`
  - Success criteria:
    - `result/bin/unreal-engine-5.sh` exists and points to the UE wrapper.

- ✅ 2.13 Completed: added `unreal-engine-5.sh` wrapper name for AUR compatibility.
  - File changed:
    - `pkgs/unreal/unreal.nix` (adds `unreal-engine-5.sh` symlink for local + installed wrappers)
  - Validation:
    - Local wrapper:
      - `cd pkgs/unreal && nix build path:.#unreal-engine --impure -L && ls -la result/bin | rg -n "unreal-engine-5\\.sh"`
      - Observed: `unreal-engine-5.sh -> ue5editor`
    - Installed wrapper:
      - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L && ls -la result/bin | rg -n "unreal-engine-5\\.sh"`
      - Observed: `unreal-engine-5.sh -> ue5editor`

- ✅ 2.14 Verified the installed-build editor can start via flake app (`unreal-editor-installed-dir`).
  - Command:
    - `cd pkgs/unreal && timeout 120s nix run path:.#unreal-editor-installed-dir -- -nullrhi -help`
  - Observed (startup logs):
    - `LogInit: Display: Running engine without a game`
    - `LogCsvProfiler: Display: Metadata set : engineversion="5.7.1-0+UE5"`
    - `LogCsvProfiler: Display: Metadata set : os="NixOS 25.11 (Xantusia) ..."`
  - Note:
    - `-help` does not exit quickly; we terminated it after confirming the editor started and printed the expected metadata.

- ✅ 2.15 Flake evaluation is now healthy again (nixpkgs fetch works).
  - Command:
    - `cd pkgs/unreal && nix flake metadata --refresh`
  - Observed:
    - `Inputs: nixpkgs: github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d (2026-01-02 ...)`

- ⚠️ 2.16 `nix develop -c ...` still does not reliably execute commands with `buildFHSEnv`.
  - Command (attempted):
    - `cd pkgs/unreal && nix develop --impure -c bash -lc 'echo OK'`
  - Observed:
    - `nix develop` entered an interactive FHS `bash` (ignoring the requested `-c ...`) and hung until killed.
  - Workaround:
    - Use flake apps instead:
      - `nix run path:.#unreal-fhs -- -lc '<cmd>'`
      - or `nix run path:.#unreal-setup -- --force`, `nix run path:.#unreal-build -- ...`, etc.

- ✅ 2.17 Confirmed the `git+file` vs `path:` flake-source behavior (important for this repo).
  - `nix flake show` from inside the git checkout uses `git+file://...` by default and excludes untracked files.
    - Command:
      - `cd pkgs/unreal && nix flake show`
    - Error:
      - `error: Unreal flake: required files are missing from the flake source: ...`
      - (This is expected while `pkgs/unreal/*` files are still untracked; see workaround below.)
  - Workaround used for all validation in this task:
    - `cd pkgs/unreal && nix flake show path:.` (succeeds; includes untracked `pkgs/unreal/*`)

- ✅ 2.18 Improved the flake error message for the “untracked files excluded by `git+file`” case.
  - File changed:
    - `pkgs/unreal/flake.nix` (checks required `pkgs/unreal/*` files and throws a guided error suggesting `path:.`)
  - Validation:
    - `cd pkgs/unreal && nix flake show` now fails with a clear message listing missing files + “use `path:.`”.
    - `cd pkgs/unreal && nix flake show path:.` still succeeds.

## Installed-build runtime bug: running from /nix/store is not writable (2026-01-19)

### Symptom (reported by user)

When running the packaged installed build, UnrealEditor launches UnrealBuildTool in `QueryTargets` mode and tries to write target info under the engine directory in `/nix/store/...`:

```
Launching UnrealBuildTool... [/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux/Engine/Build/BatchFiles/Linux/Build.sh -Mode=QueryTargets -Output="/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux/Engine/Intermediate/TargetInfo.json" ...]
LogDesktopPlatform: Warning: Unable to read target info for engine
```

On NixOS, `/nix/store` is read-only at runtime, so any attempt to write `Engine/Intermediate/*` inside the store will fail. This likely causes the “Unable to read target info” warning and may prevent the editor from behaving correctly.

### Fix plan (small diffs + real validation)

2.19 Reproduce + capture the real failure (not just the warning).
  - Commands:
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
    - `cd pkgs/unreal && timeout 180s ./result-installed/bin/UnrealEditor -nullrhi -help`
  - Success criteria:
    - We can see whether the process exits early and whether there are permission errors / missing-file errors beyond the target-info warning.

2.20 Confirm where the `TargetInfo.json` output path is computed.
  - Read-only inspection:
    - Inspect `Build.sh` root detection:
      - `sed -n '1,200p' /nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux/Engine/Build/BatchFiles/Linux/Build.sh`
    - Locate other references to `QueryTargets` / `TargetInfo.json` in UE scripts (to see if there is an env var override):
      - `rg -n "QueryTargets|TargetInfo\\.json" /nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux/Engine | head -n 50`
  - Success criteria:
    - Identify whether the engine root is derived from `/proc/self/exe`, `readlink -f "$0"`, etc. This determines whether a symlink overlay is sufficient or we must copy some entrypoints.

2.21 Implement a runtime overlay for the installed build (avoid writes to `/nix/store`).
  - Files to modify:
    - `pkgs/unreal/unreal.nix` (installed `UnrealEditor` wrapper only)
  - Approach (preferred, minimal):
    - When the installed build lives under `/nix/store`, create a **writable run root** under:
      - `$XDG_CACHE_HOME/unreal-engine/store-overlay/<store-basename>/`
    - Populate it with symlinks to the store tree, but make these writable:
      - `Engine/Intermediate/`
      - `Engine/Saved/`
      - (optionally) `Engine/DerivedDataCache/` if UE tries to write there
    - To avoid the engine “resolving back” to the store via `/proc/self/exe`, copy (not symlink) the main editor entrypoint:
      - `Engine/Binaries/Linux/UnrealEditor`
    - To ensure UBT invocation uses a writable engine root, copy the script entrypoint(s) used by the editor:
      - `Engine/Build/BatchFiles/**` (small; safe to copy)
    - Then run the editor from the overlay root inside the FHS env.
  - Success criteria:
    - Re-running `./result-installed/bin/UnrealEditor ...` no longer tries to write to `/nix/store/.../Engine/Intermediate/*`.
    - `TargetInfo.json` gets created under the overlay’s `Engine/Intermediate/`.

2.22 Validate fix end-to-end and record logs.
  - Commands:
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
    - `cd pkgs/unreal && timeout 180s ./result-installed/bin/UnrealEditor -nullrhi -help`
    - Confirm file created:
      - `test -f ~/.cache/unreal-engine/store-overlay/*/Engine/Intermediate/TargetInfo.json && echo OK`
  - Success criteria:
    - Editor reaches an observable stage (`Engine is initialized...`) and does not exit immediately due to inability to write into the store.

### User report follow-up: “Received signal 15 (SIGTERM)” during editor run

Hypothesis (to validate):
- The `Received signal 15` line is emitted by **Unreal Trace Server** (UTS) during shutdown, not necessarily by `UnrealEditor` itself.
- If the editor exits early (e.g. due to failing to write engine state under `/nix/store`), the wrapper/container teardown will SIGTERM leftover daemons (like UTS). That makes SIGTERM look like “the editor got killed”, while it’s actually the helper daemon being stopped.

2.23 Reproduce without injecting SIGTERM and capture which process prints “Received signal 15”.
  - Commands (do NOT use default `timeout`, because it sends SIGTERM):
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
    - `cd pkgs/unreal && timeout -s INT 180s ./result-installed/bin/UnrealEditor -nullrhi -unattended -stdout -FullStdOutLogOutput -log`
  - What to record:
    - exit code
    - whether we see “Permission denied / read-only filesystem” messages
    - whether “Received signal 15” is preceded by trace-server strings (“Terminating server…”, “Listening cancelled…”)
  - Success criteria:
    - Clear evidence whether SIGTERM is a root cause or an effect of editor exit.

### 2026-01-19

- Context refresh:
  - Canonical state lives in `pkgs/unreal/plan.md` (this file); `task_plan.md`, `findings.md`, `progress.md` are pointers.
  - Current reported blocker: runtime message about **signal 15 (SIGTERM)** during `UnrealEditor` run.
  - Working hypothesis (from 2.23): SIGTERM may be from teardown of helper daemons (UTS) *after* the editor exits (e.g. due to writes to `/nix/store`), not the primary root cause.
- Next: execute 2.19–2.23 with real logs, then implement 2.21 overlay if `/nix/store` write attempts are confirmed.

- ✅ 2.19 Reproduced the installed-build `/nix/store` write issue (captured full log).
  - Command:
    - `cd pkgs/unreal && timeout -s INT 90s ./result-installed/bin/UnrealEditor -nullrhi -unattended -stdout -FullStdOutLogOutput -log > /tmp/ue-installed-run.log 2>&1`
  - Result: timed out as expected (exit `124`), but we captured the key lines:
    - `Launching UnrealBuildTool... [.../Engine/Build/BatchFiles/Linux/Build.sh -Mode=QueryTargets -Output="/nix/store/h9bc...-UnrealEngine-installed-linux/Engine/Intermediate/TargetInfo.json" ...]`
    - `LogDesktopPlatform: Warning: Unable to read target info for engine`
  - Conclusion:
    - The editor indeed tries to generate `Engine/Intermediate/TargetInfo.json` *inside* the installed-build store path, which is read-only on NixOS.

- ✅ 2.21 Implemented a runtime store-overlay so the installed build can write engine state.
  - File changed:
    - `pkgs/unreal/unreal.nix` (installed `UnrealEditor` wrapper)
  - Behavior:
    - Creates per-package overlay under:
      - `$XDG_CACHE_HOME/unreal-engine/store-overlay/<store-basename>/`
    - Symlinks most of the installed build to `/nix/store`, but creates writable:
      - `Engine/Intermediate/`
      - `Engine/Saved/`
      - `Engine/DerivedDataCache/`
    - Copies `Engine/Binaries/Linux/UnrealEditor` into the overlay and runs *that* copy so `/proc/self/exe` resolves to the overlay (making the engine root writable from UE’s point of view).
  - Rebuild:
    - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc...-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
  - Validation:
    - `cd pkgs/unreal && timeout -s INT 90s ./result-installed/bin/UnrealEditor -nullrhi -unattended -stdout -FullStdOutLogOutput -log > /tmp/ue-installed-run2.log 2>&1`
    - `Launching UnrealBuildTool... [.../store-overlay/.../Engine/Build/BatchFiles/Linux/Build.sh -Mode=QueryTargets -Output="/home/vitalyr/.cache/unreal-engine/store-overlay/.../Engine/Intermediate/TargetInfo.json" ...]`
    - `TargetInfo.json` was created successfully under the overlay (no more `/nix/store/.../Engine/Intermediate/*` write attempts).

### 2026-01-19 — Root cause update: not SIGTERM, but SIGTRAP in CEF (libcef.so)

Key observation:
- The editor can *appear* to “die with SIGTERM” because **Unreal Trace Server** prints `Received signal 15` during shutdown.
- The real hard failure we observed is **SIGTRAP** (signal 5) in the editor process, with a coredump backtrace pointing into **CEF’s ProcessSingleton**.

Evidence (local, reproducible):
- `coredumpctl list --no-pager | rg -n 'UnrealEditor.*SIGTRAP'`
- `coredumpctl info <pid> --no-pager | sed -n '/Stack trace of thread <pid>/,+40p'`
  - Top frames:
    - `ImmediateCrash` → `ProcessSingleton::NotifyOtherProcessOrCreate` → `AcquireProcessSingleton` (in `libcef.so`)
    - Called from `libUnrealEditor-WebBrowser.so` while building the editor home screen.

Working hypothesis:
- CEF crashes when Chromium “singleton” artifacts are stale from a previous abnormal exit:
  - `~/.config/Epic/UnrealEngine/*/Saved/webcache*/Singleton*`
  - `/tmp/.org.chromium.Chromium.*/SingletonSocket`

Mitigation strategy (keeps GPU acceleration on):
- Pre-launch cleanup of stale Chromium singleton state (safe when no active socket exists).
- Ensure the wrapper can always run the cleanup even when launched from a GUI session (don’t depend on host `PATH`).

✅ Implemented (2026-01-19):
- `pkgs/unreal/unreal.nix`
  - Wrapper now sets `PATH` via `wrapperBinPath` (includes `coreutils`, `gnugrep`, `iproute2` for `ss`).
  - This makes the CEF singleton cleanup reliable regardless of launcher environment.

✅ Implemented (2026-01-19): more aggressive CEF webcache cleanup (prevents recurring ProcessSingleton crashes)
- Motivation: we observed repeated `SIGTRAP` coredumps in `libcef.so` (`ImmediateCrash` in `ProcessSingleton`) when stale Chromium singleton artifacts exist under UE’s webcache.
- Change: wrapper now supports `UE_CEF_CLEANUP_MODE` (default: `aggressive`)
  - `aggressive`: if `webcache*` contains any `Singleton*` artifacts, delete the **entire** webcache directory (guarantees no stale singleton survives).
  - `safe`: keep previous behavior (remove only singleton lock/cookie/socket when not in use).
  - `none`: disable cleanup completely (not recommended if you hit SIGTRAP crashes).
- Notes:
  - This does not disable Vulkan/GPU rendering; it only affects embedded browser cache state.
  - Deleting the webcache may reset embedded browser state (login/session data), but is the most reliable workaround.

Validation commands:
- Build wrapper:
  - `cd pkgs/unreal && nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
- Run with GPU (no `-nullrhi`):
  - `cd pkgs/unreal && ./result-installed/bin/UnrealEditor -stdout -FullStdOutLogOutput -log`
- Optional: if you want to silence UnrealTraceServer output (including `Received signal 15` on shutdown):
  - add `-traceautostart=0` to the command line (does not affect Vulkan/GPU rendering).
- If it exits/crashes, capture evidence:
  - `coredumpctl list --no-pager | tail -n 5`
  - `coredumpctl info <pid> --no-pager | sed -n '/Stack trace of thread <pid>/,+40p'`
  - `tail -n 200 ~/.config/Epic/UnrealEngine/5.7/Saved/Logs/Unreal.log`
  - `tail -n 200 ~/.config/Epic/UnrealEngine/5.7/Saved/webcache*/chrome_debug.log`

✅ Validation (2026-01-19): simulate GUI launch environment (minimal env, no PATH)
- Command:
  - `cd pkgs/unreal && timeout -s INT 15s env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_SESSION_TYPE="$XDG_SESSION_TYPE" ./result-installed/bin/UnrealEditor -stdout -FullStdOutLogOutput -log > /tmp/ue-gui-sim.log 2>&1`
- Result:
  - No new `UnrealEditor` SIGTRAP coredumps were created (last `coredumpctl` entry unchanged).
  - Confirms wrapper is no longer dependent on desktop/session PATH for cleanup.

---

## 2026-01-19 — New crash class: SIGSEGV in Vulkan swapchain on Wayland (NVIDIA)

User symptom:
- “Welcome screen shows, but after that the editor exits; can’t reach open/new project UI.”

✅ Evidence (coredump + full backtrace):
- `coredumpctl list --no-pager | tail -n 10` shows new `UnrealEditor` crashes with **Signal 11 (SEGV)**.
- Example (latest):
  - PID: `1762059`
  - Command line:
    - `.../UnrealEditor /home/vitalyr/projects/dev/Unreal/MyProject2/MyProject2.uproject -stdout -FullStdOutLogOutput -log`
  - Backtrace (gdb via `coredumpctl debug`):
    - `FVulkanSwapChain::Create` → `vkGetPhysicalDeviceSurfaceFormatsKHR` (at `VulkanSwapChain.cpp:211`)
    - then into NVIDIA driver (`libnvidia-glcore.so.580.95.05`) and eventually `0x0` (null) → SIGSEGV
  - Full captured text: `/tmp/ue-coredump-1762059-bt.txt`

✅ Likely root cause:
- UE 5.7 uses **SDL3 + Vulkan** on Linux.
- In our logs, SDL chose the **Wayland** backend (`LogInit: Using SDL video driver 'wayland'`), which causes UE to create a Wayland Vulkan surface.
- On this NVIDIA stack, querying surface formats via Vulkan WSI on Wayland can crash inside the driver (instead of returning an error).

Workaround that keeps GPU acceleration on:
- Force UE/SDL to use **X11/XWayland** instead of native Wayland:
  - `SDL_VIDEODRIVER=x11`
  - This keeps Vulkan/GPU rendering enabled, but uses the X11 WSI path instead of Wayland.

✅ Quick validation (manual env override, no code changes):
- Command:
  - `cd pkgs/unreal && timeout -s INT 90s env SDL_VIDEODRIVER=x11 ./result-installed/bin/UnrealEditor /home/vitalyr/projects/dev/Unreal/MyProject2/MyProject2.uproject -stdout -FullStdOutLogOutput -log > /tmp/ue-myproject2-x11.log 2>&1`
- Result:
  - No SIGSEGV (run survived until timeout/SIGINT).
  - Log shows CEF GPU-process init errors (ANGLE/Vulkan), but the editor itself stays alive.

Next step (code):
- Make the wrapper automatically prefer `SDL_VIDEODRIVER=x11` when:
  - `XDG_SESSION_TYPE=wayland` or `WAYLAND_DISPLAY` is set
  - `DISPLAY` is set (XWayland available)
  - NVIDIA driver is detected (e.g. `/proc/driver/nvidia/version` exists)
  - and the user didn’t explicitly set `SDL_VIDEODRIVER`
- Provide an explicit override knob (e.g. `UE_SDL_VIDEODRIVER=...`) to force wayland for testing.

✅ Implemented (2026-01-19):
- `pkgs/unreal/unreal.nix`
  - Wrapper now auto-forces `SDL_VIDEODRIVER=x11` on Wayland sessions when NVIDIA is detected.
  - Wrapper-specific override: `UE_SDL_VIDEODRIVER=wayland|x11`.
  - Important: the wrapper will override an ambient `SDL_VIDEODRIVER=wayland` (common in Wayland desktops) unless `UE_SDL_VIDEODRIVER` is set.

✅ Validation (2026-01-19):
- Build:
  - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
- Run (project open path that used to SIGSEGV):
  - `cd pkgs/unreal && timeout -s INT 30s ./result-installed/bin/UnrealEditor /home/vitalyr/projects/dev/Unreal/MyProject2/MyProject2.uproject -stdout -FullStdOutLogOutput -log > /tmp/ue-myproject2-wrapper.log 2>&1`
- Check:
  - `/tmp/ue-myproject2-wrapper.log` contains:
    - `UE SDL: forcing SDL_VIDEODRIVER=x11 ...`
    - `LogInit: Using SDL video driver 'x11'`
  - No new `UnrealEditor` coredumps were created (`coredumpctl list --no-pager -1` unchanged).

---

## 2026-01-19 — Code review + small hardening tweaks

Goal:
- Keep the working fix, but reduce footguns / noise and avoid unintended overrides.

✅ Improvements applied:
- `pkgs/unreal/unreal.nix`
  - `SDL_VIDEODRIVER` override logic:
    - now respects user-provided `SDL_VIDEODRIVER` values (anything other than `wayland`)
    - still overrides the common ambient `SDL_VIDEODRIVER=wayland` on Wayland+NVIDIA (crash workaround)
  - CEF singleton cleanup:
    - avoid `rm -f "$wc"/Singleton*` under `nullglob` (can emit “missing operand” noise when no matches)
    - remove singleton files via the already-computed array (`singleton_files`) only when non-empty
    - treat a non-symlink `SingletonSocket` (actual socket file) as “in use” when detected in `ss -xl`

✅ Rebuild + verification:
- Build:
  - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
- Open project (smoke test; ensure no crash):
  - `cd pkgs/unreal && timeout -s INT 60s ./result-installed/bin/UnrealEditor /home/vitalyr/projects/dev/Unreal/MyProject2/MyProject2.uproject -stdout -FullStdOutLogOutput -log > /tmp/ue-verify-open-project.log 2>&1`
  - Evidence in `/tmp/ue-verify-open-project.log`:
    - `LogInit: Display: Running engine for game: MyProject2`
    - `LogInit: Using SDL video driver 'x11'`
    - shader compilation + DDC activity (indicates the editor is progressing, not crashing)
  - Coredumps:
    - `coredumpctl list --no-pager -1` unchanged (no new `UnrealEditor` crash).

Repo hygiene:
- Ignore Nix build outputs (`result`, `result-*`) via repo-root `.gitignore`.
- Make sure `pkgs/unreal/result*` symlinks never get committed.

---

## 2026-01-19 — Remove `pkgs/unreal/shell.nix` (flake-only workflow)

Decision:
- `pkgs/unreal/shell.nix` is no longer needed:
  - `pkgs/unreal/flake.nix` already provides:
    - `apps.${system}.unreal-fhs` (`nix run path:.#unreal-fhs`)
    - `devShells.${system}.default` (`nix develop`)
  - Wrapper packages and BuildGraph helpers use the flake-provided FHS env directly.

Changes:
- Deleted: `pkgs/unreal/shell.nix`
- Updated: `pkgs/unreal/.envrc`
  - removed references to `shell.nix`/`nix-shell`
  - clarified that `.envrc` launches the flake `unreal-fhs` app

Validation:
- `cd pkgs/unreal && nix flake show path:.` still works (flake eval does not depend on `shell.nix`).
- `nix build path:.#unreal-engine-installed` still builds and runs (see previous “Open project” smoke test).

---

## 2026-01-19 — New instability: Vulkan + NVIDIA GPU hang / device lost (plus occasional allocator crashes)

User report:
- Editor initially usable, later freezes and UE reports a crash.
- Crash report shows:
  - `Caught signal 11 Segmentation fault`
  - mimalloc frames (`_mi_free_delayed_block`, `FMallocMimalloc::Realloc`)
  - Vulkan RHI frame: `VulkanRHI::FDeferredDeletionQueue2::ReleaseResources(bool)`

Primary on-disk evidence (full logs):
- Crash bundle is under the **project** crash directory, not under `~/.config/Epic/...`:
  - `~/projects/dev/Unreal/MyProject2/Saved/Crashes/crashinfo-MyProject2-pid-1834131-AD13E59614CA409FAD3BC2E5BDAA4901/Diagnostics.txt`
  - `~/projects/dev/Unreal/MyProject2/Saved/Crashes/crashinfo-MyProject2-pid-1834131-AD13E59614CA409FAD3BC2E5BDAA4901/MyProject2_2.log`

Critical new discovery:
- Kernel logs show NVIDIA GPU hang events for UnrealEditor:
  - `NVRM: Xid ... 109 ... errorString CTX SWITCH TIMEOUT`
  - This aligns with UE logs we reproduced showing `VK_ERROR_DEVICE_LOST` and `FVulkanDynamicRHI.TerminateOnGPUCrash`.
- Therefore: the “SIGSEGV in mimalloc” is likely a *symptom* / secondary failure mode; the dominant root cause is **GPU hangs/device loss** on this NVIDIA stack.

Mitigation approach (must keep GPU acceleration on):
- Add wrapper-level Vulkan workarounds (no UE source edits / no rebuild):
  1) Disable Vulkan timeline semaphore submission path on NVIDIA (reduces submission-thread complexity):
     - via `-cvarsini=<file>` with `r.Vulkan.Submission.AllowTimelineSemaphores=0`
  2) Prefer Vulkan present mode FIFO (vsync) on NVIDIA (reduces “run as fast as possible” stress):
     - via `-vulkanpresentmode=2` (FIFO)

✅ Implemented in wrapper (2026-01-19):
- `pkgs/unreal/unreal.nix`
  - New env knobs:
    - `UE_VULKAN_TIMELINE_SEMAPHORES=auto|on|off|none`
      - default `auto`: on NVIDIA → `off` (adds `-cvarsini=...` that sets `r.Vulkan.Submission.AllowTimelineSemaphores=0`)
    - `UE_VULKAN_PRESENT_MODE=auto|fifo|mailbox|immediate|none`
      - default `auto`: on NVIDIA → `fifo` (adds `-vulkanpresentmode=2`)
  - Both respect user-supplied args:
    - if you pass your own `-cvarsini=...`, wrapper does not override it
    - if you pass your own `-vulkanpresentmode=...`, wrapper does not override it

✅ Additional mitigation (2026-01-20):
- We observed that some `NVRM: Xid 109` events may be coming from **CEF/Chromium GPU subprocesses** (they also show up as `name=UnrealEditor` in kernel logs).
- Since CEF GPU-process init was already error-prone (ANGLE init failures), we add an **optional** wrapper-level knob to disable *CEF only* GPU acceleration (does not disable UE Vulkan rendering).
- `pkgs/unreal/unreal.nix`:
  - New env knob: `UE_CEF_GPU_ACCELERATION=auto|on|off|none`
    - default `auto`: if NVIDIA “Open Kernel Module” is detected, set `r.CEFGPUAcceleration=0` via wrapper-generated `-cvarsini=...`
  - Wrapper now generates a single `wrapper-cvars.ini` when needed:
    - contains `r.Vulkan.Submission.AllowTimelineSemaphores=0` (if enabled)
    - contains `r.CEFGPUAcceleration=0/1` (if enabled)

✅ Validation (2026-01-19):
- Rebuild wrapper-only package:
  - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
- Smoke-run shows the wrapper injections are active:
  - `/tmp/ue-wrapper-default.log` contains:
    - `UE Vulkan: forcing present mode (-vulkanpresentmode=2)`
    - `UE Vulkan: disabling timeline semaphores via -cvarsini=...`
    - `LogVulkanRHI: ... Selected VkPresentModeKHR mode VK_PRESENT_MODE_FIFO_KHR`

Next step:
- User re-test a longer interactive session with the updated wrapper. If you still hit GPU hangs:
  - collect `journalctl -k` lines around the crash (look for `NVRM: Xid ... 109`)
  - attach the newest `Saved/Crashes/.../Diagnostics.txt` + `*.log` from the project crash folder

---

## 2026-01-20 — Root cause confirmed: VK_ERROR_DEVICE_LOST (Xid 109) triggered by Virtual Shadow Maps; add `UE_GPU_SAFE_MODE`

New evidence (read from disk; no user copy/paste needed):
- Project log shows a hard Vulkan device loss:
  - `~/projects/dev/Unreal/MyProject2/Saved/Logs/MyProject2_2.log`
  - `VulkanRHI::vkQueueSubmit ... failed ... VK_ERROR_DEVICE_LOST`
  - `FUnixPlatformMisc::RequestExit(1, FVulkanDynamicRHI.TerminateOnGPUCrash)`
  - GPU breadcrumbs show the active pass at the time of the fault:
    - `Shadow.Virtual.ProcessInvalidations` (Virtual Shadow Maps)
- Kernel log correlates 1:1 with that timestamp:
  - `journalctl -k` shows `NVRM: Xid ... 109 ... CTX SWITCH TIMEOUT` for `name=UnrealEditor`.

Conclusion:
- The dominating failure mode is **NVIDIA GPU hang (Xid 109) → VK_ERROR_DEVICE_LOST**, not a timeout/SIGTERM.
- The allocator SIGSEGVs (mimalloc/binned2) are secondary symptoms after the renderer becomes unstable.

Mitigation direction (keep GPU rendering on):
- Reduce or disable the specific rendering feature that correlates with the device loss:
  - Virtual Shadow Maps (VSM): `r.Shadow.Virtual.Enable=0`

✅ Wrapper change (implemented):
- `pkgs/unreal/unreal.nix`:
  - New env knob: `UE_GPU_SAFE_MODE=auto|on|off|none`
    - default `auto`: on NVIDIA Open Kernel Module → `on`
    - `on`: adds `r.Shadow.Virtual.Enable=0` into wrapper-generated `-cvarsini=...`
  - This keeps Vulkan rendering enabled, but avoids the VSM path that triggered the device loss.
  - Also extended `UE_CEF_CLEANUP_MODE` to support `force` (optional extra-aggressive webcache cleanup).

Trade-offs (what changes when we disable VSM):
- VSM = Virtual Shadow Maps (`r.Shadow.Virtual.Enable`).
- Disabling it does NOT disable GPU rendering; it changes the shadow method back to classic shadow maps.
- Expected impacts:
  - Shadow quality may degrade (more aliasing/shimmering, more bias tuning needed).
  - For projects that use Nanite:
    - UE has a MapCheck warning stating Nanite works best with VSM enabled.
    - Nanite geometry does not support *stationary light shadows* without VSM (per UE source message).

✅ Build:
- `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`

✅ Smoke verification (short):
- Ran the editor with the wrapper defaults and confirmed:
  - wrapper emits `UE GPU: applying safe-mode CVars... (UE_GPU_SAFE_MODE=on)`
  - UE log shows `LogConfig: Set CVar [[r.Shadow.Virtual.Enable:0]]`
  - no `VK_ERROR_DEVICE_LOST` and no `NVRM: Xid 109` in kernel logs during that short run.

Next step:
- User do a longer interactive session:
  - If stable: we keep `UE_GPU_SAFE_MODE` as default for NVIDIA OpenKM.
  - If still hits Xid/device lost: expand the safe-mode CVars to also reduce Nanite/Lumen (still GPU on), but only after confirming which pass is active in the breadcrumbs.

---

## 2026-01-20 — Refactor: keep package code split out of `flake.nix` (rename `unreal.nix` → `package.nix`)

Question:
- Is the previously-added `pkgs/unreal/unreal.nix` still necessary, or can `pkgs/unreal/flake.nix` fully replace it?

Decision:
- `flake.nix` *can* technically inline everything, but we keep a dedicated package-definition file to:
  - avoid making `flake.nix` ~1000 lines longer (harder to review/maintain)
  - support a multi-package repo structure (`pkgs/<name>/package.nix` pattern)
  - keep `flake.nix` focused on wiring outputs (FHS env + helper apps + package exports)

Change (implemented):
- Renamed the package-definition file:
  - `pkgs/unreal/unreal.nix` → `pkgs/unreal/package.nix`
- Updated `pkgs/unreal/flake.nix` to import `./package.nix` (and to treat it as a required file for the flake source).

Notes:
- Historical references to `pkgs/unreal/unreal.nix` in older logs are now “past tense”; the current implementation lives in `pkgs/unreal/package.nix`.
