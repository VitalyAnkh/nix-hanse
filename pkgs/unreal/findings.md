# Findings (pointer)

Canonical research notes: `pkgs/unreal/plan.md` (see “Phase 0 findings”).

---

## 2026-01-19 — Runtime “SIGTERM” investigation findings

### 1) “Received signal 15 (SIGTERM)” is not the root failure

- The `Received signal 15` line is emitted by **Unreal Trace Server** (UTS) during shutdown.
- We observed it in captured stdout logs *after* `FUnixPlatformMisc::RequestExit...` and UTS shutdown messages (`Terminating server...`, `Listening cancelled...`).
- It can appear even on a normal, user-initiated exit (e.g. `Ctrl+C` / `SIGINT`) because the wrapper/container teardown terminates the trace daemon.
- If you want to suppress this entirely (optional), UE supports disabling trace auto-start via:
  - `-traceautostart=0` (does **not** disable Vulkan/GPU rendering; it only affects tracing/UTS).

### 2) Real root cause of the editor dying: SIGTRAP in CEF (libcef.so)

- `coredumpctl` shows repeated crashes of `UnrealEditor` with **Signal 5 (TRAP)**.
- Backtrace points to Chromium/CEF process singleton startup:
  - `ImmediateCrash` → `ProcessSingleton::NotifyOtherProcessOrCreate` → `AcquireProcessSingleton` (in `libcef.so`)
  - Called from `libUnrealEditor-WebBrowser.so` while creating the editor home screen (`FMainFrameModule::CreateHomeScreenWidget`).
- This matches a known Chromium pattern: `ImmediateCrash` is typically a `CHECK()` / assertion failure, not “memory overflow”.

### 3) Concrete on-disk trigger: stale Chromium singleton state from UE webcache

- UE’s CEF user-data dir is under:
  - `~/.config/Epic/UnrealEngine/<version>/Saved/webcache*/`
- After abnormal exits, Chromium leaves “singleton” artifacts:
  - `SingletonLock`, `SingletonCookie`, `SingletonSocket`
  - `/tmp/.org.chromium.Chromium.*/SingletonSocket`
- We observed `SingletonLock` becoming a **dangling symlink** (`-> muon-<pid>`, target missing) and a stale `/tmp/.org.chromium...` directory with a socket file but no listening process.
- Removing this stale singleton state prevents the SIGTRAP crash and allows the editor to start (with GPU/Vulkan enabled).

### 4) Fix direction

- Ensure the `UnrealEditor` wrapper always performs CEF singleton cleanup **before** launching.
- Make the wrapper reliable when launched from GUI/desktop by not depending on the session’s `PATH`:
  - Set `PATH` inside the wrapper to include `ss` (iproute2) and basic tools.
  - Implemented in `pkgs/unreal/unreal.nix` via `wrapperBinPath`.
- Make cleanup stronger to eliminate recurring ProcessSingleton failures:
  - Wrapper now supports `UE_CEF_CLEANUP_MODE` (default: `aggressive`).
  - In `aggressive` mode, if UE webcache (`webcache*`) contains any `Singleton*` artifacts, we delete the entire webcache directory.
  - This is intentionally heavy-handed but reliably prevents the SIGTRAP `ImmediateCrash` in `libcef.so` across launches.

### 5) Secondary observation: CEF GPU process may log Vulkan/ANGLE init errors

- `chrome_debug.log` under UE webcache can show ANGLE Vulkan init failures and “Exiting GPU process due to errors during initialization”.
- This seems to affect the embedded browser process more than the editor’s Vulkan RHI (the editor can still create a swapchain), but it is useful diagnostic data if web UI/widgets misbehave.

---

## 2026-01-19 — New root cause: SIGSEGV in NVIDIA Vulkan WSI on Wayland

This explains the “welcome screen shows briefly then editor exits” symptom when opening/creating a project.

### Evidence

- `coredumpctl list --no-pager` shows recent `UnrealEditor` crashes with **Signal 11 (SEGV)**.
- A representative crash (PID `1762059`) has a gdb backtrace that shows:
  - Crash thread: RHI thread during Vulkan swapchain creation.
  - UE frame:
    - `FVulkanSwapChain::Create` at `Engine/Source/Runtime/VulkanRHI/Private/VulkanSwapChain.cpp:211`
    - specifically inside `vkGetPhysicalDeviceSurfaceFormatsKHR(...)`
  - Driver frames:
    - in `libnvidia-glcore.so.580.95.05` then jump to `0x0` → SIGSEGV
- Captured full backtrace text: `/tmp/ue-coredump-1762059-bt.txt`

### Why this happens

- UE 5.7 on Linux uses SDL3; by default on a Wayland session SDL picked `wayland` (`LogInit: Using SDL video driver 'wayland'`).
- That makes UE use Vulkan’s **Wayland surface** path.
- On this NVIDIA driver stack, the Wayland WSI path appears unstable and can segfault inside the driver during surface format queries.

### Workaround (keeps GPU acceleration)

Force SDL to use X11/XWayland:
- `SDL_VIDEODRIVER=x11`

This keeps Vulkan/GPU rendering enabled, but routes presentation via X11 WSI instead of Wayland WSI.

### Wrapper support (implemented)

- The `UnrealEditor` wrapper now auto-applies this on Wayland+NVIDIA by default.
- Override knob:
  - `UE_SDL_VIDEODRIVER=wayland` to force native Wayland (for testing)
  - `UE_SDL_VIDEODRIVER=x11` to force X11/XWayland

---

## 2026-01-19 — Small wrapper hardening notes

### `nullglob` + `rm` noise

- In bash, `shopt -s nullglob` makes unmatched globs expand to nothing.
- `rm -f "$wc"/Singleton*` can become `rm -f` (no args) and print “missing operand”.
- Fix: use the computed array and only call `rm` when it is non-empty:
  - `singleton_files=("$wc"/Singleton*)`
  - `if (( ${#singleton_files[@]} > 0 )); then rm -f "${singleton_files[@]}"; fi`

### Singleton socket “in use” detection

- Chromium typically uses a symlink `webcache*/SingletonSocket -> /tmp/.org.chromium.Chromium.*`.
- Some layouts can leave a real socket file at `webcache*/SingletonSocket`.
- Treat `-S "$wc/SingletonSocket"` as “in use” when it appears in `ss -xl` to avoid deleting active webcache state.

---

## 2026-01-19 — Repo note: flake replaces `shell.nix`

- We now treat `pkgs/unreal/flake.nix` as the single source of truth for the FHS environment:
  - `nix run path:.#unreal-fhs`
  - `nix develop`
- `pkgs/unreal/shell.nix` was removed to avoid divergence.

---

## 2026-01-19 — New instability: Vulkan + NVIDIA GPU hangs (Xid 109) → VK_ERROR_DEVICE_LOST → secondary crashes

### 1) The “mimalloc SIGSEGV” crash has a concrete crash bundle with full symbols

Crash bundle location (per-project):
- `~/projects/dev/Unreal/MyProject2/Saved/Crashes/crashinfo-MyProject2-pid-1834131-AD13E59614CA409FAD3BC2E5BDAA4901/Diagnostics.txt`
- `~/projects/dev/Unreal/MyProject2/Saved/Crashes/crashinfo-MyProject2-pid-1834131-AD13E59614CA409FAD3BC2E5BDAA4901/MyProject2_2.log`

The stack in `Diagnostics.txt` matches the user report:
- `libUnrealEditor-Core.so!_mi_free_delayed_block` (mimalloc)
- `FMallocMimalloc::Realloc`
- `VulkanRHI::FDeferredDeletionQueue2::ReleaseResources(bool)`

### 2) Kernel evidence: GPU hangs are happening (not just “UE crashed”)

`journalctl -k` shows NVIDIA Xid errors for UnrealEditor:
- `NVRM: Xid ... 109 ... errorString CTX SWITCH TIMEOUT`

This correlates with UE Vulkan logs we reproduced:
- `VK_ERROR_DEVICE_LOST`
- `FUnixPlatformMisc::RequestExit(..., FVulkanDynamicRHI.TerminateOnGPUCrash)`

Interpretation:
- This is primarily a **GPU hang / device lost** situation.
- Allocator crashes (mimalloc / binned2) are likely secondary symptoms after the device is already in a bad state, or triggered by racey submission paths.

### 3) Wrapper-level mitigations (keep GPU on; no UE source edits)

Implemented in `pkgs/unreal/unreal.nix`:

- `UE_VULKAN_TIMELINE_SEMAPHORES=auto|on|off|none`
  - default `auto` disables timeline semaphores on NVIDIA by passing `-cvarsini=...` with:
    - `r.Vulkan.Submission.AllowTimelineSemaphores=0`
- `UE_VULKAN_PRESENT_MODE=auto|fifo|mailbox|immediate|none`
  - default `auto` forces FIFO present mode on NVIDIA:
    - `-vulkanpresentmode=2` → `VK_PRESENT_MODE_FIFO_KHR`

Both are override-friendly:
- If the user supplies `-cvarsini=...` themselves, the wrapper does not add another one.
- If the user supplies `-vulkanpresentmode=...` themselves, the wrapper does not add one.

### 4) Note: NVIDIA Xid 109 may be coming from CEF GPU subprocess, not the main 3D renderer

- Chromium/CEF subprocesses are spawned as the same executable (`UnrealEditor`) and can show up in kernel logs as:
  - `NVRM: Xid ... pid=<pid>, name=UnrealEditor ...`
- We repeatedly see Chromium-style GPU-process init errors in stdout logs:
  - `Exiting GPU process due to errors during initialization`
  - ANGLE failures (often referencing Vulkan/ANGLE internals)
- This makes it ambiguous whether an Xid 109 is caused by the main UE Vulkan RHI workload, or by the embedded browser’s GPU-process.

Mitigation we can apply without disabling UE’s GPU rendering:
- Disable **CEF** GPU acceleration (only the embedded browser UI) via `r.CEFGPUAcceleration=0`.

Wrapper support (implemented):
- New wrapper env knob:
  - `UE_CEF_GPU_ACCELERATION=auto|on|off|none`
  - default `auto`: on NVIDIA **Open Kernel Module** → `off`
    - detection: `/proc/driver/nvidia/version` contains `Open Kernel Module`

---

## 2026-01-20 — Confirmed: GPU hang (Xid 109) → VK_ERROR_DEVICE_LOST while VSM invalidates

### 1) The crash is a real Vulkan device loss, not “random SIGTERM”

Project log (full path on disk):
- `~/projects/dev/Unreal/MyProject2/Saved/Logs/MyProject2_2.log`

Key lines:
- `VulkanRHI::vkQueueSubmit ... failed ... with error VK_ERROR_DEVICE_LOST`
- `DEVICE FAULT REPORT:` (via `VK_EXT_device_fault`)
- `FUnixPlatformMisc::RequestExit(1, FVulkanDynamicRHI.TerminateOnGPUCrash)`

### 2) Breadcrumbs point at Virtual Shadow Maps as the active pass

In the same log, `Active GPU breadcrumbs` shows the active scope at the time of failure:
- `Shadow.Virtual.ProcessInvalidations`

This matches the user symptom:
- “initially usable → later freeze → UE reports a crash”

### 3) Kernel Xid 109 correlates exactly with the UE log timestamp

Kernel log around the same time:
- `journalctl -k --since '2026-01-20 10:30' --until '2026-01-20 10:45' | rg 'NVRM: Xid'`

Contains:
- `NVRM: Xid ... 109 ... errorString CTX SWITCH TIMEOUT` with `name=UnrealEditor`

Interpretation:
- GPU hang/reset is the primary event.
- “heap corruption” crashes (mimalloc/binned2) are likely secondary fallout after the device is already in a bad state.

### 4) Wrapper-level mitigation that keeps GPU rendering enabled

Disable Virtual Shadow Maps at startup (reduces the chance of hitting the problematic pass):
- `r.Shadow.Virtual.Enable=0`

Wrapper implementation:
- New env knob in `pkgs/unreal/unreal.nix`:
  - `UE_GPU_SAFE_MODE=auto|on|off|none`
  - default `auto`: on NVIDIA Open Kernel Module → `on`
  - `on`: writes `r.Shadow.Virtual.Enable=0` into the wrapper `-cvarsini=...`

### Note on file names (2026-01-20)

- The package-definition file was renamed:
  - `pkgs/unreal/unreal.nix` → `pkgs/unreal/package.nix`
- Historical notes may still mention the old path; the current implementation is in `pkgs/unreal/package.nix`.

---

## 2026-01-20 — What is VSM (Virtual Shadow Maps) and what changes if we disable it?

### Definition (what VSM is)

VSM = **Virtual Shadow Maps** (UE5’s “next-gen” shadow map method).

In UE source, the CVar is defined as:
- `r.Shadow.Virtual.Enable`
- Description in `Engine/Source/Runtime/Renderer/Private/VirtualShadowMaps/VirtualShadowMapArray.cpp`:
  - “Renders geometry into virtualized shadow depth maps for shadowing”
  - “Provides high-quality shadows for next-gen projects… High efficiency culling when used with Nanite”

“Virtualized” here means it behaves like virtual texturing:
- Shadow depth is stored in a **page pool** (tiles/pages).
- The engine only allocates/renders the pages needed for what’s visible, and can cache pages across frames.
- There is explicit page marking, caching, and **invalidation** work (this matches our breadcrumb `Shadow.Virtual.ProcessInvalidations`).

### Practical impact of disabling VSM (`r.Shadow.Virtual.Enable=0`)

Disabling VSM does **not** disable GPU rendering. It only changes the *shadow* technique.

What you can expect in the editor/game:

1) Shadow method fallback
- UE falls back to the classic (non-virtual) shadow map path (e.g. cascaded shadow maps for directional lights, standard shadow maps for local lights).
- You may need more manual tuning (shadow distance/resolution/bias), because VSM is designed to “just work” across large ranges.

2) Visual/quality changes
- Usually: lower shadow detail at distance, more aliasing/shimmering, more bias artifacts (acne/peter-panning) unless tuned.
- VSM typically gives more consistent detail, especially in large scenes and with Nanite geometry.

3) Nanite-specific caveats (important)
- UE has an explicit MapCheck warning for this case:
  - `Engine/Source/Runtime/Engine/Private/Components/StaticMeshComponent.cpp`
  - “Nanite … but Virtual Shadow Maps are not enabled… Nanite geometry does not support stationary light shadows, and may yield poor visual quality and reduced performance… Nanite geometry works best with virtual shadow maps enabled.”
- Meaning:
  - If your project uses **Nanite meshes**, turning off VSM can reduce shadow quality and may change which light mobility options produce correct shadows.
  - In particular: **Stationary light shadows with Nanite are not supported** without VSM (per that message).

4) Why disabling VSM helps stability on this machine
- Our crash breadcrumbs show the device fault while executing a VSM pass:
  - `Shadow.Virtual.ProcessInvalidations`
- By disabling VSM we remove that entire pipeline (page allocation, invalidation, related compute/raster paths),
  which reduces the chance of hitting the NVIDIA Open Kernel Module hang (`Xid 109`).
