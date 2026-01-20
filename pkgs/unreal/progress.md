# Progress (pointer)

Canonical progress log: `pkgs/unreal/plan.md` (see “Execution log”).

---

## 2026-01-19 — Session log (SIGTERM / crash investigation)

### What we observed

- Terminal logs showed `Received signal 15`; user suspected it was UnrealEditor being SIGTERM’d.
- System had repeated `UnrealEditor` core dumps with **SIGTRAP**.

### What we did (high-signal steps)

- Located engine logs under `~/.config/Epic/UnrealEngine/5.7/Saved/Logs/`.
- Captured stdout runs to `/tmp/ue-installed-run*.log` and `/tmp/ue-ui-run*.log`.
- Verified the “signal 15” line comes from **Unreal Trace Server** output, not the editor itself.
- Pulled the real crash reason from systemd-coredump:
  - `coredumpctl info <pid>` shows `ImmediateCrash` inside `libcef.so` (`ProcessSingleton::NotifyOtherProcessOrCreate`).
- Inspected UE CEF webcache:
  - Found stale singleton artifacts under `~/.config/Epic/UnrealEngine/5.7/Saved/webcache*` and `/tmp/.org.chromium.Chromium.*`.
- Manually cleaned stale singleton state and confirmed the editor can start without immediately crashing.

### Code change made

- Updated wrapper scripts to be PATH-stable (so cleanup works from GUI sessions too):
  - `pkgs/unreal/unreal.nix` now sets `PATH` using `wrapperBinPath` (includes coreutils + grep + iproute2/ss).
- Made CEF cleanup more aggressive to avoid recurring `libcef.so` ProcessSingleton SIGTRAP:
  - `UE_CEF_CLEANUP_MODE` added (default `aggressive`).
  - In aggressive mode, if `webcache*` contains any `Singleton*`, delete the entire directory.

### Next actions

- Rebuild `result-installed` after wrapper change and confirm:
  - No new `UnrealEditor` SIGTRAP coredumps on launch.
  - GPU/Vulkan startup succeeds (no `-nullrhi`).

### Validation done

- Simulated GUI launch environment (no PATH) and confirmed wrapper still works:
  - `timeout -s INT 15s env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_SESSION_TYPE="$XDG_SESSION_TYPE" ./result-installed/bin/UnrealEditor ...`
  - No new SIGTRAP coredumps were created (last `coredumpctl` entry unchanged).
- Verified aggressive cleanup triggers on demand:
  - Created a sentinel `SingletonLock` in `~/.config/Epic/UnrealEngine/5.7/Saved/webcache_6613/`.
  - Next launch printed `UE CEF cleanup: deleting webcache dir...` and the sentinel file was removed.

### Context restart reminder (planning-with-files hygiene)

On context restart / new session:
- Read `pkgs/unreal/plan.md` (canonical plan + log).
- Read `pkgs/unreal/findings.md` (key discoveries).
- Read `pkgs/unreal/progress.md` (what was tried and results).

---

## 2026-01-19 — Session log (project open / “welcome then exit”)

### What we observed

- `Unreal.log` often looks like a clean shutdown (it can print `LogExit: Exiting.`), but `coredumpctl list` shows the editor actually crashed with **SIGSEGV** shortly after.

### What we did

- Read the full logs:
  - `~/.config/Epic/UnrealEngine/5.7/Saved/Logs/Unreal.log` (no fatal/assert lines)
  - `~/.config/Epic/UnrealEngine/5.7/Saved/Logs/cef3.log` (CEF GPU-process restarts)
- Pulled the real crash cause from systemd-coredump using gdb:
  - `coredumpctl debug <pid> --debugger=gdb -A \"-nx -batch -ex bt\"`
  - For PID `1762059`, backtrace shows a crash in:
    - `FVulkanSwapChain::Create` (`VulkanSwapChain.cpp:211`, `vkGetPhysicalDeviceSurfaceFormatsKHR`)
    - then into `libnvidia-glcore.so.580.95.05`
- Tested a Wayland→X11 workaround without code changes:
  - Ran with `SDL_VIDEODRIVER=x11` and confirmed the editor stayed alive (no SIGSEGV before timeout).

### Next action

- Codify the workaround in the wrapper so users don’t need to remember it:
  - auto-set `SDL_VIDEODRIVER=x11` on Wayland+NVIDIA when XWayland is available
  - add an explicit override env var for testing/forcing Wayland

### Code change made

- Updated `pkgs/unreal/unreal.nix` wrappers:
  - Auto-force `SDL_VIDEODRIVER=x11` on Wayland+NVIDIA (prevents Vulkan swapchain SIGSEGV).
  - Added wrapper-specific override `UE_SDL_VIDEODRIVER=...`.
  - Wrapper intentionally overrides an ambient `SDL_VIDEODRIVER=wayland` unless explicitly overridden.

### Validation done

- `timeout -s INT 30s ./result-installed/bin/UnrealEditor /home/vitalyr/projects/dev/Unreal/MyProject2/MyProject2.uproject ...` no longer crashes.
- Captured output shows `LogInit: Using SDL video driver 'x11'`.

---

## 2026-01-19 — Session log (code review + verify open project)

### Code changes

- Hardened wrapper behavior without changing the overall approach:
  - Respect non-`wayland` `SDL_VIDEODRIVER` values instead of overriding all session-provided settings.
  - Fixed potential `rm -f` “missing operand” noise under `nullglob` by removing files via an array only when non-empty.
  - Added detection for a non-symlink `webcache*/SingletonSocket` socket file being active (via `ss -xl`) to avoid deleting an in-use webcache directory.

### Build + verification

- Rebuilt `unreal-engine-installed` with:
  - `UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
- Opened a project for a smoke test (killed by timeout, not a crash):
  - `/tmp/ue-verify-open-project.log` contains:
    - `LogInit: Display: Running engine for game: MyProject2`
    - `LogInit: Using SDL video driver 'x11'`
  - `coredumpctl list --no-pager -1` unchanged (no new UnrealEditor crash).

### Repo hygiene

- Added `.gitignore` to ignore Nix build output symlinks (`result`, `result-*`) and `.direnv/`.
- Removed `pkgs/unreal/result` and `pkgs/unreal/result-installed` from the git index (they are build outputs, not source).

---

## 2026-01-19 — Remove `pkgs/unreal/shell.nix`

### Why

- The flake now provides the FHS environment directly:
  - `nix run path:.#unreal-fhs`
  - `nix develop` (devShell default)
- Keeping `shell.nix` would be redundant and a maintenance burden.

### What changed

- Deleted `pkgs/unreal/shell.nix`.
- Updated `pkgs/unreal/.envrc` comments to reflect the flake-based launcher approach.

### Validation

- `nix build path:.#unreal-engine-installed --impure` still works (no dependency on `shell.nix`).
- Project-open smoke test still works with the current wrapper.

Concrete checks:
- `cd pkgs/unreal && nix flake show path:.` succeeds after deletion.
- `cd pkgs/unreal && nix develop path:. -c true` succeeds (devShell still valid without `shell.nix`).
- `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed` succeeds.
- `timeout -s INT 60s ./result-installed/bin/UnrealEditor /home/vitalyr/projects/dev/Unreal/MyProject2/MyProject2.uproject ...` runs until timeout, and `coredumpctl list --no-pager -1` remains unchanged.

---

## 2026-01-19 — Session log (mimalloc SIGSEGV + NVIDIA Xid 109 + Vulkan workarounds)

### What we saw (user report + real logs)

- User crash report stack points to:
  - mimalloc (`_mi_free_delayed_block` → `FMallocMimalloc::Realloc`)
  - Vulkan deferred deletion (`FDeferredDeletionQueue2::ReleaseResources`)
- Located the exact crash bundle on disk:
  - `~/projects/dev/Unreal/MyProject2/Saved/Crashes/crashinfo-MyProject2-pid-1834131-AD13E59614CA409FAD3BC2E5BDAA4901/Diagnostics.txt`
  - `.../MyProject2_2.log`
- Kernel logs show **NVIDIA Xid 109 CTX SWITCH TIMEOUT** for UnrealEditor:
  - `journalctl -k --no-pager | rg 'NVRM: Xid.*UnrealEditor'`

### Hypothesis

- Primary failure is GPU hang → Vulkan device lost.
- Secondary failures can manifest as allocator crashes (mimalloc/binned2) in Vulkan cleanup or submission paths.

### Code change made

- Updated wrappers in `pkgs/unreal/unreal.nix` to apply Vulkan stability workarounds by default on NVIDIA:
  - Disable Vulkan timeline semaphores via `-cvarsini=...` (`r.Vulkan.Submission.AllowTimelineSemaphores=0`)
  - Force FIFO present mode via `-vulkanpresentmode=2`
  - Added env overrides:
    - `UE_VULKAN_TIMELINE_SEMAPHORES=auto|on|off|none`
    - `UE_VULKAN_PRESENT_MODE=auto|fifo|mailbox|immediate|none`

### Build + verification

- Rebuilt `unreal-engine-installed` after wrapper change:
  - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
- Smoke-run confirmed the injected args are active:
  - `/tmp/ue-wrapper-default.log` contains:
    - `UE Vulkan: forcing present mode (-vulkanpresentmode=2)`
    - `UE Vulkan: disabling timeline semaphores via -cvarsini=...`
    - `LogVulkanRHI: ... Selected VkPresentModeKHR mode VK_PRESENT_MODE_FIFO_KHR`

### Follow-up (2026-01-20): CEF GPU-process mitigation

- Kernel log shows new `NVRM: Xid 109` even after Vulkan wrapper tweaks.
- Chromium/CEF GPU subprocesses can appear as `name=UnrealEditor` (same executable), so Xid events can be from the embedded browser, not necessarily the main renderer.
- Added a wrapper knob to disable **CEF-only** GPU acceleration (keeps UE Vulkan GPU rendering enabled):
  - `UE_CEF_GPU_ACCELERATION=auto|on|off|none`
  - default `auto`: on NVIDIA Open Kernel Module → `off`
- Rebuilt and validated wrapper prints the new injection:
  - `/tmp/ue-wrapper-cef-off.log` contains:
    - `UE CEF: setting r.CEFGPUAcceleration via -cvarsini=... (UE_CEF_GPU_ACCELERATION=off)`

---

## 2026-01-20 — Session log (device lost root-cause + safe-mode wrapper)

### What we found

- A fresh project log shows a real Vulkan device loss:
  - `~/projects/dev/Unreal/MyProject2/Saved/Logs/MyProject2_2.log`
  - `vkQueueSubmit ... VK_ERROR_DEVICE_LOST`
  - `DEVICE FAULT REPORT` + GPU breadcrumbs (active: `Shadow.Virtual.ProcessInvalidations`)
- Kernel logs for the same timestamp show:
  - `NVRM: Xid ... 109 ... CTX SWITCH TIMEOUT`

### What we changed

- `pkgs/unreal/unreal.nix`:
  - Added `UE_GPU_SAFE_MODE=auto|on|off|none`:
    - default `auto`: on NVIDIA Open Kernel Module → `on`
    - when `on`: inject `r.Shadow.Virtual.Enable=0` via wrapper `-cvarsini=...`
  - Added an optional extra-aggressive CEF cleanup mode:
    - `UE_CEF_CLEANUP_MODE=force` (deletes webcache/tmp chromium dirs even if socket appears active)

### Build + quick verification

- Rebuilt installed wrapper package (wrapper-only rebuild):
  - `cd pkgs/unreal && UE_INSTALLED_STORE_PATH=/nix/store/h9bc3r5wcsa39fycl8px26plwaqyq0im-UnrealEngine-installed-linux nix build path:.#unreal-engine-installed --impure -L --out-link result-installed`
- Smoke-run (60s) did not show `VK_ERROR_DEVICE_LOST`, and `journalctl -k` in that window did not show `NVRM: Xid 109`.
  - Wrapper confirms it applied safe mode:
    - `UE GPU: applying safe-mode CVars... (UE_GPU_SAFE_MODE=on)`
    - `LogConfig: Set CVar [[r.Shadow.Virtual.Enable:0]]`

### Follow-up (documentation)

- Added a concrete explanation of what VSM is and the expected impact of disabling it:
  - `pkgs/unreal/findings.md`
  - Includes pointers to the UE source definition of `r.Shadow.Virtual.Enable` and the MapCheck warning about Nanite + non-VSM.

---

## 2026-01-20 — Persist high-signal notes to `AGENTS.md`

User request:
- Write project-specific “gotchas” to an `AGENTS.md` so future similar work can restart faster without re-discovering everything.

Change:
- Added repo-root `AGENTS.md` documenting:
  - Scope constraints (only `pkgs/unreal/`, do not edit `~/projects/dev/cpp/UnrealEngine`)
  - The `path:.` flake gotcha (untracked files excluded by `git+file`)
  - Known runtime failure modes + wrapper mitigations:
    - CEF ProcessSingleton SIGTRAP (webcache Singleton*)
    - Wayland+NVIDIA Vulkan WSI segfault (force `SDL_VIDEODRIVER=x11`)
    - Xid 109 → `VK_ERROR_DEVICE_LOST` (VSM invalidation) + `UE_GPU_SAFE_MODE`
  - Log locations and wrapper env knobs

Follow-up (per user clarification):
- Updated `AGENTS.md` to reflect that this repo is **multi-package** (`pkgs/*`), and Unreal is only one package.
- Moved Unreal details under an explicit `Unreal Engine (pkgs/unreal/)` section, keeping a small repo-wide section for flake `path:.` gotcha.

---

## 2026-01-20 — Refactor: `unreal.nix` → `package.nix`

User question:
- Whether `pkgs/unreal/unreal.nix` is still needed or if `pkgs/unreal/flake.nix` can replace it.

Decision:
- Keep a split between “flake wiring” and “package definition”, but rename the file to reduce confusion and make the structure reusable for other packages.

Changes:
- Renamed `pkgs/unreal/unreal.nix` → `pkgs/unreal/package.nix`.
- Updated `pkgs/unreal/flake.nix` imports and required-file checks accordingly.

---

## 2026-01-20 — Document build/run + env vars in `AGENTS.md`

User request:
- Put build/run commands and all relevant environment variables into `AGENTS.md` for future reuse.

Change:
- Expanded `AGENTS.md` with:
  - “which run mode to pick” (local source vs installed dir vs packaged installed build)
  - canonical `nix run` / `nix build` commands
  - a curated list of environment variables (BuildGraph + runtime wrapper knobs)
  - removed duplicate env-var listing at the end of `AGENTS.md` (kept a single authoritative list)
