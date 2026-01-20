# Agent Notes: nix-hanse (NixOS packages repo)

This repository contains **multiple** NixOS/Nix packages and experiments under `pkgs/`.

`pkgs/unreal/` (Unreal Engine 5) is one package among others; it just happens to have a lot of
special runtime/driver gotchas, so it has a larger “deep notes” section below.

These notes capture the highest-signal discoveries and “gotchas” so future work can be resumed quickly.

## Repo-wide Notes

### Flake development gotcha: prefer `path:.` during iteration

When running flake commands from inside a git checkout, Nix may use an implicit `git+file://...` URL
which **excludes untracked files** from the flake source. During iteration (new files not committed yet),
use `path:.` so evaluation includes untracked files:

- Example: `cd pkgs/<pkg> && nix flake show path:.`

(`pkgs/unreal/flake.nix` also throws a helpful error if required files are missing due to this.)

## Unreal Engine (`pkgs/unreal/`)

### Scope / Constraints (Unreal-specific)

- For Unreal packaging/runtime fixes, **only modify files under `pkgs/unreal/`**.
- **Do not edit** the Unreal source tree under `~/projects/dev/cpp/UnrealEngine` (no patches/config changes there).
- **GPU rendering must remain enabled** (solutions must not rely on `-nullrhi` or “disable GPU acceleration”).

### Persistent Planning Memory (required on context restart; Unreal-specific)

Canonical task memory lives under `pkgs/unreal/`:
- `pkgs/unreal/plan.md` (single source of truth)
- `pkgs/unreal/findings.md`
- `pkgs/unreal/progress.md`

Repo-root `task_plan.md` / `findings.md` / `progress.md` are pointers only.

### Build / Run (common commands)

#### Quick “where am I running?”

There are multiple supported ways to run UE on NixOS in this repo; pick based on your goal:

1) **Local source tree run** (uses `UE_SRC=~/.../UnrealEngine`):
   - Wrapper package: `.#unreal-engine`
   - Runs the editor from your UE checkout inside the flake FHS env.

2) **Installed BuildGraph output (direct)** (no Nix-store import of the 50G tree):
   - App: `.#unreal-editor-installed-dir`
   - Runs `$UE_INSTALLED_DIR/Engine/Binaries/Linux/UnrealEditor` inside FHS.

3) **Installed BuildGraph output (packaged)** (imports installed build into `/nix/store` once):
   - Package: `.#unreal-engine-installed`
   - Provides an overlay+wrapper so UE can write runtime state without touching `/nix/store`.

#### Flake helpers (recommended entrypoints)

- Enter the FHS shell (useful for ad-hoc debugging):
  - `cd pkgs/unreal && nix run path:.#unreal-fhs`
- Run UE Setup in FHS:
  - `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-setup -- --force`
- Generate project files in FHS:
  - `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-generate-project-files --`
- Build targets in FHS (examples):
  - `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- UnrealEditor Linux Development -Progress`
  - `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- ShaderCompileWorker Linux Development -Progress`
- Build “Installed Build Linux” (BuildGraph) in FHS:
  - `UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build-installed -- --with-ddc=false`

### Build installed wrapper package

Use `UE_INSTALLED_STORE_PATH` when available to avoid re-importing huge trees:
- `cd pkgs/unreal`
- `UE_INSTALLED_STORE_PATH=/nix/store/<...>-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`

Alternatively, import a local installed-build directory into the store + build the wrapper in one step:
- `cd pkgs/unreal`
- `nix run path:.#unreal-package-installed -- --installed-dir "$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux"`

### Run editor (installed build)

- `cd pkgs/unreal`
- `./result-installed/bin/UnrealEditor /home/vitalyr/projects/dev/Unreal/MyProject2/MyProject2.uproject -stdout -FullStdOutLogOutput -log`

### Run editor (local UE source tree)

Build the wrapper:
- `cd pkgs/unreal && nix build path:.#unreal-engine -L --out-link result-local`

Run (editor from `UE_SRC` inside FHS):
- `UE_SRC=~/projects/dev/cpp/UnrealEngine ./result-local/bin/UnrealEditor -stdout -FullStdOutLogOutput -log`

### Run installed build directly (no Nix-store import)

- `UE_INSTALLED_DIR="$HOME/.cache/unreal-engine/LocalBuilds/Engine/Linux" nix run path:.#unreal-editor-installed-dir -- -stdout -FullStdOutLogOutput -log`

## Unreal Environment Variables (important)

### BuildGraph / build helpers

- `UE_SRC`:
  - Path to UE source checkout (default: `~/projects/dev/cpp/UnrealEngine`).
  - Used by `unreal-setup`, `unreal-generate-project-files`, `unreal-build`, `unreal-build-installed`.
- `UE_BUILTDIR`:
  - BuildGraph “BuiltDirectory” (default: `$HOME/.cache/unreal-engine/LocalBuilds/Engine`).
  - Installed build ends up under `$UE_BUILTDIR/Linux`.
- `UE_INSTALLED_DIR`:
  - Path to installed build output dir (default: `$UE_BUILTDIR/Linux`).
  - Used by `unreal-editor-installed-dir` and by `unreal-engine-installed` when not using `UE_INSTALLED_STORE_PATH`.
- `UE_INSTALLED_STORE_PATH`:
  - Existing `/nix/store/...-UnrealEngine-installed-linux` path to reuse (avoids re-importing).
  - Used by `nix build path:.#unreal-engine-installed --impure`.
- `UE_SETUP_ALLOW_GIT_HOOKS=1`:
  - Opt-in: let `Setup.sh` write `.git/hooks/*`. Default wrapper behavior is to avoid modifying hooks.
- `UE_GITDEPS_ARGS`:
  - Optional extra args to GitDependencies/Setup to exclude platforms (saves disk/time).
- `DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER=0`:
  - Workaround mirrored from AUR; set by wrappers that invoke Setup/BuildGraph.

### Runtime wrapper knobs (GPU must stay on)

All are implemented in `pkgs/unreal/package.nix` and apply to both the local and installed wrappers.

**Core stability toggles**
- `UE_SDL_VIDEODRIVER=x11|wayland`
- `UE_VULKAN_PRESENT_MODE=auto|fifo|mailbox|immediate|none`
- `UE_VULKAN_TIMELINE_SEMAPHORES=auto|on|off|none`
- `UE_GPU_SAFE_MODE=auto|on|off|none` (disables VSM via `r.Shadow.Virtual.Enable=0` when `on`)

**CEF / browser**
- `UE_CEF_CLEANUP_MODE=aggressive|safe|force|none`
- `UE_CEF_GPU_ACCELERATION=auto|on|off|none`

**Allocator**
- `UE_MALLOC_MODE=auto|mimalloc|binned2|binned|ansi|jemalloc|none`

The wrapper may generate `~/.cache/unreal-engine/wrapper/wrapper-cvars.ini` and pass it via `-cvarsini=...`.

### Known Runtime Failure Modes + Fixes

### 1) SIGTRAP in `libcef.so` (Chromium ProcessSingleton)

Symptom:
- `coredumpctl` shows `Signal 5 (TRAP)` with frames in `libcef.so` `ProcessSingleton::NotifyOtherProcessOrCreate`.

Cause:
- Stale Chromium singleton artifacts after abnormal shutdown:
  - `~/.config/Epic/UnrealEngine/<ver>/Saved/webcache*/Singleton*`
  - `/tmp/.org.chromium.Chromium.*/SingletonSocket`

Fix:
- Wrapper performs pre-launch cleanup.
- Control via env:
  - `UE_CEF_CLEANUP_MODE=aggressive|safe|force|none`
  - Default is `aggressive`.
  - `force` is “most aggressive” (can delete even if socket looks active).

Implementation:
- `pkgs/unreal/package.nix` wrapper logic.

### 2) Wayland + NVIDIA Vulkan WSI segfault on launch

Symptom:
- Welcome screen flashes, then crash (SIGSEGV) inside NVIDIA driver while creating Vulkan swapchain / querying surface formats.

Fix (keeps GPU rendering enabled):
- Force SDL to use X11/XWayland:
  - `SDL_VIDEODRIVER=x11`
- Wrapper does this automatically on Wayland+NVIDIA (unless explicitly overridden).
- Override knob:
  - `UE_SDL_VIDEODRIVER=x11|wayland`

### 3) NVIDIA GPU hang → `Xid 109` → `VK_ERROR_DEVICE_LOST`

Symptom:
- Editor works briefly then freezes/crashes.
- Project log shows:
  - `VK_ERROR_DEVICE_LOST`
  - `FVulkanDynamicRHI.TerminateOnGPUCrash`
- Kernel log shows:
  - `NVRM: Xid ... 109 ... CTX SWITCH TIMEOUT`
- GPU breadcrumbs often show the fault during a VSM pass:
  - `Shadow.Virtual.ProcessInvalidations` (Virtual Shadow Maps)

Mitigations applied in wrapper (still GPU-on):
- `UE_VULKAN_PRESENT_MODE=auto` → on NVIDIA forces FIFO via `-vulkanpresentmode=2`.
- `UE_VULKAN_TIMELINE_SEMAPHORES=auto` → on NVIDIA disables timeline semaphores via `-cvarsini`:
  - `r.Vulkan.Submission.AllowTimelineSemaphores=0`
- `UE_MALLOC_MODE=auto` → on NVIDIA adds `-binnedmalloc2` (stability workaround).
- `UE_CEF_GPU_ACCELERATION=auto` → on NVIDIA Open Kernel Module disables CEF GPU accel:
  - `r.CEFGPUAcceleration=0` (CEF-only; UE Vulkan still on).
- **`UE_GPU_SAFE_MODE=auto`** → on NVIDIA Open Kernel Module disables Virtual Shadow Maps:
  - `r.Shadow.Virtual.Enable=0`
  - This keeps GPU rendering on but changes shadow method to reduce risk of device loss.

### Log / Debug Locations

- Project logs:
  - `~/projects/dev/Unreal/<Project>/Saved/Logs/*.log`
- Project crash bundles:
  - `~/projects/dev/Unreal/<Project>/Saved/Crashes/*/Diagnostics.txt`
- Engine/global logs:
  - `~/.config/Epic/UnrealEngine/<ver>/Saved/Logs/`
- Kernel GPU hang evidence:
  - `journalctl -k --no-pager | rg 'NVRM: Xid'`
- systemd-coredump:
  - `coredumpctl list --no-pager | rg UnrealEditor`

### Wrapper Knobs (environment variables)

See the “Runtime wrapper knobs (GPU must stay on)” section above for the authoritative list.
