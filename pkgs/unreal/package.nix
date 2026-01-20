# Unreal Engine package definition (wrappers + installed-build packaging)
{
  pkgs,
  unrealFhs,
  buildInstalled ? false,
  withDDC ? false,
  ueSrc ?
    let
      env = builtins.getEnv "UE_SRC";
    in
    if env != "" then env else "/home/vitalyr/projects/dev/cpp/UnrealEngine",
}:

let
  lib = pkgs.lib;

  ueSrcStr = toString ueSrc;

  wrapperBinPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.iproute2
  ];

  localUnrealEditor = pkgs.writeShellScriptBin "UnrealEditor" ''
    set -euo pipefail

    export PATH="${wrapperBinPath}:''${PATH-}"

    if [[ "$(id -u)" -eq 0 ]]; then
      echo "ERROR: Run this as an unprivileged user; not as root." >&2
      exit 1
    fi

    maybe_force_sdl_videodriver() {
      # Allow explicit override:
      # - UE_SDL_VIDEODRIVER=wayland (force native Wayland)
      # - UE_SDL_VIDEODRIVER=x11     (force X11/XWayland)
      if [[ -n "''${UE_SDL_VIDEODRIVER:-}" ]]; then
        export SDL_VIDEODRIVER="''${UE_SDL_VIDEODRIVER}"
        echo "UE SDL: SDL_VIDEODRIVER set from UE_SDL_VIDEODRIVER=$UE_SDL_VIDEODRIVER" >&2
        return 0
      fi

      # Respect explicit user choice, except for the common "wayland" default
      # which is known to crash on some NVIDIA+Wayland Vulkan stacks.
      if [[ -n "''${SDL_VIDEODRIVER:-}" && "''${SDL_VIDEODRIVER}" != "wayland" ]]; then
        return 0
      fi

      # Workaround: UE 5.7 + SDL3 + Vulkan on NVIDIA can crash (SIGSEGV in the
      # driver) when using native Wayland WSI while querying swapchain surface
      # formats (vkGetPhysicalDeviceSurfaceFormatsKHR).
      #
      # Prefer X11/XWayland when available.
      if [[ -n "''${WAYLAND_DISPLAY:-}" || "''${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        if [[ -n "''${DISPLAY:-}" && -e /proc/driver/nvidia/version ]]; then
          local prev_sdl_videodriver
          prev_sdl_videodriver="''${SDL_VIDEODRIVER:-<unset>}"
          export SDL_VIDEODRIVER="x11"
          echo "UE SDL: forcing SDL_VIDEODRIVER=x11 (Wayland+NVIDIA Vulkan WSI crash workaround; was: $prev_sdl_videodriver)" >&2
        fi
      fi
    }

    maybe_force_sdl_videodriver || true

    maybe_force_allocator_args() {
      # User can override explicitly (highest priority):
      #   UE_MALLOC_MODE=auto|mimalloc|binned2|binned|ansi|jemalloc|none
      #
      # Default (auto):
      #   - On NVIDIA: prefer `-binnedmalloc2` for stability (workaround for
      #     observed mimalloc crashes under heavy Vulkan workloads).
      #   - Otherwise: keep UE default allocator (currently mimalloc).
      local mode
      mode="''${UE_MALLOC_MODE:-auto}"
      case "$mode" in
        auto|mimalloc|binned2|binned|ansi|jemalloc|none) ;;
        *)
          mode="auto"
          ;;
      esac

      # If the user already supplied an allocator switch, respect it.
      local arg
      for arg in "$@"; do
        case "$arg" in
          -ansimalloc|-binnedmalloc|-binnedmalloc2|-mimalloc|-jemalloc)
            return 0
            ;;
        esac
      done

      local flag
      flag=""
      case "$mode" in
        none) flag="" ;;
        mimalloc) flag="-mimalloc" ;;
        binned2) flag="-binnedmalloc2" ;;
        binned) flag="-binnedmalloc" ;;
        ansi) flag="-ansimalloc" ;;
        jemalloc) flag="-jemalloc" ;;
        auto)
          if [[ -e /proc/driver/nvidia/version ]]; then
            flag="-binnedmalloc2"
          fi
          ;;
      esac

      if [[ -n "$flag" ]]; then
        echo "UE malloc: adding allocator switch $flag (UE_MALLOC_MODE=$mode)" >&2
        printf '%s\n' "$flag"
      fi
    }

    mapfile -t UE_EXTRA_ARGS < <(maybe_force_allocator_args "$@" || true)

    maybe_force_vulkan_present_mode_args() {
      # UE supports selecting Vulkan present mode via:
      #   -vulkanpresentmode=<VkPresentModeKHR enum integer>
      #
      # Wrapper override:
      #   UE_VULKAN_PRESENT_MODE=auto|fifo|mailbox|immediate|none
      #
      # Default (auto):
      #   - On NVIDIA: prefer FIFO (vsync) to reduce the risk of GPU hangs (Xid 109)
      #   - Otherwise: keep UE default selection
      local mode
      mode="''${UE_VULKAN_PRESENT_MODE:-auto}"
      case "$mode" in
        auto|fifo|mailbox|immediate|none) ;;
        *)
          mode="auto"
          ;;
      esac

      # Respect explicit user choice.
      local arg
      for arg in "$@"; do
        case "$arg" in
          *vulkanpresentmode=*)
            return 0
            ;;
        esac
      done

      local present_mode
      present_mode=""
      case "$mode" in
        none) present_mode="" ;;
        fifo) present_mode="2" ;;      # VK_PRESENT_MODE_FIFO_KHR
        mailbox) present_mode="1" ;;   # VK_PRESENT_MODE_MAILBOX_KHR
        immediate) present_mode="0" ;; # VK_PRESENT_MODE_IMMEDIATE_KHR
        auto)
          if [[ -e /proc/driver/nvidia/version ]]; then
            present_mode="2"
          fi
          ;;
      esac

      if [[ -n "$present_mode" ]]; then
        echo "UE Vulkan: forcing present mode (-vulkanpresentmode=$present_mode) (UE_VULKAN_PRESENT_MODE=$mode)" >&2
        printf '%s\n' "-vulkanpresentmode=$present_mode"
      fi
    }

    mapfile -t UE_VULKAN_PRESENT_ARGS < <(maybe_force_vulkan_present_mode_args "$@" || true)

    maybe_force_cvarsini_args() {
      # UE supports overriding startup console variables via:
      #   -cvarsini=/path/to/file.ini
      #
      # We use this to apply runtime workarounds without rebuilding the engine.
      #
      # Wrapper knobs:
      #   UE_VULKAN_TIMELINE_SEMAPHORES=auto|on|off|none
      #     - default auto: on NVIDIA -> off (avoid RHISubmissionThread path)
      #
      #   UE_CEF_GPU_ACCELERATION=auto|on|off|none
      #     - default auto: on NVIDIA Open Kernel Module -> off (avoid CEF GPU-process churn)
      #
      #   UE_GPU_SAFE_MODE=auto|on|off|none
      #     - default auto: on NVIDIA Open Kernel Module -> on (avoid Xid 109 / device lost)
      #
      # IMPORTANT: Respect a user-provided -cvarsini=...

      local arg
      for arg in "$@"; do
        case "$arg" in
          -cvarsini=*)
            return 0
            ;;
        esac
      done

      local want_file
      want_file=0

      local -a cvars_lines
      cvars_lines=()

      # Vulkan timeline semaphores
      local timeline_mode
      timeline_mode="''${UE_VULKAN_TIMELINE_SEMAPHORES:-auto}"
      case "$timeline_mode" in
        auto|on|off|none) ;;
        *) timeline_mode="auto" ;;
      esac
      if [[ "$timeline_mode" == "auto" && -e /proc/driver/nvidia/version ]]; then
        timeline_mode="off"
      fi
      if [[ "$timeline_mode" == "off" ]]; then
        want_file=1
        cvars_lines+=("r.Vulkan.Submission.AllowTimelineSemaphores=0")
      fi

      # CEF GPU acceleration (affects embedded browser UI; not UE's Vulkan RHI)
      local cef_mode
      cef_mode="''${UE_CEF_GPU_ACCELERATION:-auto}"
      case "$cef_mode" in
        auto|on|off|none) ;;
        *) cef_mode="auto" ;;
      esac
      if [[ "$cef_mode" == "auto" ]]; then
        if [[ -e /proc/driver/nvidia/version ]] && grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
          cef_mode="off"
        else
          cef_mode="none"
        fi
      fi
      case "$cef_mode" in
        on)
          want_file=1
          cvars_lines+=("r.CEFGPUAcceleration=1")
          ;;
        off)
          want_file=1
          cvars_lines+=("r.CEFGPUAcceleration=0")
          ;;
      esac

      # GPU stability mode (keep GPU rendering on; reduce risky rendering features)
      #
      # Observed on this machine/driver:
      # - Kernel: `NVRM: Xid 109 ... CTX SWITCH TIMEOUT`
      # - UE log: `VK_ERROR_DEVICE_LOST` with active GPU breadcrumb in
      #   `Shadow.Virtual.ProcessInvalidations`
      #
      # Primary mitigation: disable Virtual Shadow Maps (VSM).
      local gpu_safe_mode
      gpu_safe_mode="''${UE_GPU_SAFE_MODE:-auto}"
      case "$gpu_safe_mode" in
        auto|on|off|none) ;;
        *) gpu_safe_mode="auto" ;;
      esac
      if [[ "$gpu_safe_mode" == "auto" ]]; then
        if [[ -e /proc/driver/nvidia/version ]] && grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
          gpu_safe_mode="on"
        else
          gpu_safe_mode="none"
        fi
      fi
      if [[ "$gpu_safe_mode" == "on" ]]; then
        want_file=1
        cvars_lines+=("r.Shadow.Virtual.Enable=0")
      fi

      if [[ "$want_file" != 1 ]]; then
        return 0
      fi

      local cache_home cvars_dir cvars_file
      cache_home="''${XDG_CACHE_HOME:-''${HOME:-/tmp}/.cache}"
      cvars_dir="$cache_home/unreal-engine/wrapper"
      mkdir -p "$cvars_dir"
      cvars_file="$cvars_dir/wrapper-cvars.ini"

      {
        echo "[Startup]"
        printf '%s\n' "''${cvars_lines[@]}"
      } >"$cvars_file"

      if [[ "$timeline_mode" == "off" ]]; then
        echo "UE Vulkan: disabling timeline semaphores via -cvarsini=$cvars_file (UE_VULKAN_TIMELINE_SEMAPHORES=$timeline_mode)" >&2
      fi
      if [[ "$cef_mode" == "off" || "$cef_mode" == "on" ]]; then
        echo "UE CEF: setting r.CEFGPUAcceleration via -cvarsini=$cvars_file (UE_CEF_GPU_ACCELERATION=$cef_mode)" >&2
      fi
      if [[ "$gpu_safe_mode" == "on" ]]; then
        echo "UE GPU: applying safe-mode CVars via -cvarsini=$cvars_file (UE_GPU_SAFE_MODE=$gpu_safe_mode)" >&2
      fi

      printf '%s\n' "-cvarsini=$cvars_file"
    }

    mapfile -t UE_CVARS_ARGS < <(maybe_force_cvarsini_args "$@" || true)

    cleanup_cef_singletons() {
      if [[ -z "''${HOME:-}" ]]; then
        return 0
      fi

      local config_home tmp_dir have_ss cleanup_mode
      config_home="''${XDG_CONFIG_HOME:-$HOME/.config}"
      tmp_dir="''${TMPDIR:-/tmp}"

      have_ss=0
      if command -v ss >/dev/null 2>&1; then
        have_ss=1
      fi

      cleanup_mode="''${UE_CEF_CLEANUP_MODE:-aggressive}"
      case "$cleanup_mode" in
        aggressive|safe|force|none) ;;
        *)
          cleanup_mode="aggressive"
          ;;
      esac

      if [[ "$cleanup_mode" == "none" ]]; then
        return 0
      fi

      # If UE/CEF previously crashed, it can leave behind Chromium "singleton" state
      # (SingletonLock/Cookie/Socket and /tmp/.org.chromium.Chromium.*). On the next
      # launch, libcef may crash in ProcessSingleton while trying to notify the
      # non-existent prior instance.
      #
      # Fix: remove stale singleton state when it is clearly not active.

      # Clean stale /tmp/.org.chromium.Chromium.* dirs (safe: do not touch active ones).
      if [[ "$have_ss" == 1 ]]; then
        shopt -s nullglob
        for dir in "$tmp_dir"/.org.chromium.Chromium.*; do
          [[ -d "$dir" ]] || continue
          if [[ "$cleanup_mode" != "force" ]] && ss -xl 2>/dev/null | grep -F -q "$dir/SingletonSocket"; then
            continue
          fi
          rm -rf "$dir" || true
        done
      fi

      # Clean UE webcache singleton links if their socket isn't active.
      shopt -s nullglob
      for wc in "$config_home"/Epic/UnrealEngine/*/Saved/webcache*; do
        [[ -d "$wc" ]] || continue

        local in_use socket_target socket_dir socket_path has_singleton
        in_use=0
        has_singleton=0

        local -a singleton_files
        singleton_files=("$wc"/Singleton*)
        if (( "''${#singleton_files[@]}" > 0 )); then
          has_singleton=1
        fi

        if [[ -L "$wc/SingletonSocket" ]]; then
          socket_target="$(readlink "$wc/SingletonSocket" || true)"
          if [[ "$socket_target" == "$tmp_dir"/.org.chromium.Chromium.*/* ]]; then
            socket_dir="$(dirname "$socket_target")"
            socket_path="$socket_dir/SingletonSocket"
            if [[ "$have_ss" == 1 ]] && ss -xl 2>/dev/null | grep -F -q "$socket_path"; then
              in_use=1
            else
              if [[ "$have_ss" == 1 ]]; then
                rm -rf "$socket_dir" || true
              fi
            fi
          fi
        fi
        if [[ -S "$wc/SingletonSocket" ]]; then
          socket_path="$wc/SingletonSocket"
          if [[ "$have_ss" == 1 ]] && ss -xl 2>/dev/null | grep -F -q "$socket_path"; then
            in_use=1
          fi
        fi

        # "Aggressive" mode: if Chromium singleton artifacts exist, delete the
        # entire UE CEF webcache dir to guarantee no stale ProcessSingleton state
        # survives across launches (prevents libcef ImmediateCrash/SIGTRAP).
        if [[ "$has_singleton" == 1 && ( "$cleanup_mode" == "aggressive" || "$cleanup_mode" == "force" ) ]]; then
          if [[ "$in_use" == 1 && "$cleanup_mode" != "force" ]]; then
            echo "UE CEF cleanup: webcache appears in use; not deleting: $wc" >&2
          else
            echo "UE CEF cleanup: deleting webcache dir due to Singleton* artifacts: $wc" >&2
            rm -rf "$wc" || true
          fi
          continue
        fi

        if [[ "$in_use" == 0 ]]; then
          if (( "''${#singleton_files[@]}" > 0 )); then
            rm -f "''${singleton_files[@]}" || true
          fi
        fi
      done
    }

    cleanup_cef_singletons || true

    UE_SRC="''${UE_SRC:-${ueSrcStr}}"
    if [[ ! -d "$UE_SRC" ]]; then
      echo "ERROR: UE source dir not found: $UE_SRC" >&2
      echo "Set UE_SRC=/abs/path/to/UnrealEngine (or use the default clone path)." >&2
      exit 1
    fi
    if [[ ! -x "$UE_SRC/Engine/Binaries/Linux/UnrealEditor" ]]; then
      echo "ERROR: UnrealEditor not found at: $UE_SRC/Engine/Binaries/Linux/UnrealEditor" >&2
      echo "Expected a prepared + built UE tree at UE_SRC." >&2
      echo "Phase 1 commands (inside FHS):" >&2
      echo "  cd \"$UE_SRC\" && ./Setup.sh --force" >&2
      echo "  cd \"$UE_SRC\" && ./GenerateProjectFiles.sh" >&2
      echo "  cd \"$UE_SRC\" && ./Engine/Build/BatchFiles/Linux/Build.sh UnrealEditor Linux Development -Progress" >&2
      echo "  cd \"$UE_SRC\" && ./Engine/Build/BatchFiles/Linux/Build.sh ShaderCompileWorker Linux Development -Progress" >&2
      exit 1
    fi

    exec ${unrealFhs}/bin/ue5-fhs -lc 'ulimit -n 16000 || true; UE_SRC="$1"; shift; cd "$UE_SRC"; exec "$UE_SRC/Engine/Binaries/Linux/UnrealEditor" "$@"' bash "$UE_SRC" "''${UE_EXTRA_ARGS[@]}" "''${UE_VULKAN_PRESENT_ARGS[@]}" "''${UE_CVARS_ARGS[@]}" "$@"
  '';

  localWrapper = pkgs.symlinkJoin {
    name = "unreal-engine-local-wrapper";
    paths = [ localUnrealEditor ];
    postBuild = ''
      ln -s UnrealEditor "$out/bin/ue5editor"
      ln -s ue5editor "$out/bin/ue5"
      ln -s ue5editor "$out/bin/UE5"
      ln -s ue5editor "$out/bin/unreal-engine-5"
      ln -s ue5editor "$out/bin/unreal-engine-5.sh"
    '';
  };

  installedUnrealEditor = pkgs.writeShellScriptBin "UnrealEditor" ''
    set -euo pipefail

    export PATH="${wrapperBinPath}:''${PATH-}"

    if [[ "$(id -u)" -eq 0 ]]; then
      echo "ERROR: Run this as an unprivileged user; not as root." >&2
      exit 1
    fi

    maybe_force_sdl_videodriver() {
      # Allow explicit override:
      # - UE_SDL_VIDEODRIVER=wayland (force native Wayland)
      # - UE_SDL_VIDEODRIVER=x11     (force X11/XWayland)
      if [[ -n "''${UE_SDL_VIDEODRIVER:-}" ]]; then
        export SDL_VIDEODRIVER="''${UE_SDL_VIDEODRIVER}"
        echo "UE SDL: SDL_VIDEODRIVER set from UE_SDL_VIDEODRIVER=$UE_SDL_VIDEODRIVER" >&2
        return 0
      fi

      # Respect explicit user choice, except for the common "wayland" default
      # which is known to crash on some NVIDIA+Wayland Vulkan stacks.
      if [[ -n "''${SDL_VIDEODRIVER:-}" && "''${SDL_VIDEODRIVER}" != "wayland" ]]; then
        return 0
      fi

      # Workaround: UE 5.7 + SDL3 + Vulkan on NVIDIA can crash (SIGSEGV in the
      # driver) when using native Wayland WSI while querying swapchain surface
      # formats (vkGetPhysicalDeviceSurfaceFormatsKHR).
      #
      # Prefer X11/XWayland when available.
      if [[ -n "''${WAYLAND_DISPLAY:-}" || "''${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        if [[ -n "''${DISPLAY:-}" && -e /proc/driver/nvidia/version ]]; then
          local prev_sdl_videodriver
          prev_sdl_videodriver="''${SDL_VIDEODRIVER:-<unset>}"
          export SDL_VIDEODRIVER="x11"
          echo "UE SDL: forcing SDL_VIDEODRIVER=x11 (Wayland+NVIDIA Vulkan WSI crash workaround; was: $prev_sdl_videodriver)" >&2
        fi
      fi
    }

    maybe_force_sdl_videodriver || true

    maybe_force_allocator_args() {
      # User can override explicitly (highest priority):
      #   UE_MALLOC_MODE=auto|mimalloc|binned2|binned|ansi|jemalloc|none
      #
      # Default (auto):
      #   - On NVIDIA: prefer `-binnedmalloc2` for stability (workaround for
      #     observed mimalloc crashes under heavy Vulkan workloads).
      #   - Otherwise: keep UE default allocator (currently mimalloc).
      local mode
      mode="''${UE_MALLOC_MODE:-auto}"
      case "$mode" in
        auto|mimalloc|binned2|binned|ansi|jemalloc|none) ;;
        *)
          mode="auto"
          ;;
      esac

      # If the user already supplied an allocator switch, respect it.
      local arg
      for arg in "$@"; do
        case "$arg" in
          -ansimalloc|-binnedmalloc|-binnedmalloc2|-mimalloc|-jemalloc)
            return 0
            ;;
        esac
      done

      local flag
      flag=""
      case "$mode" in
        none) flag="" ;;
        mimalloc) flag="-mimalloc" ;;
        binned2) flag="-binnedmalloc2" ;;
        binned) flag="-binnedmalloc" ;;
        ansi) flag="-ansimalloc" ;;
        jemalloc) flag="-jemalloc" ;;
        auto)
          if [[ -e /proc/driver/nvidia/version ]]; then
            flag="-binnedmalloc2"
          fi
          ;;
      esac

      if [[ -n "$flag" ]]; then
        echo "UE malloc: adding allocator switch $flag (UE_MALLOC_MODE=$mode)" >&2
        printf '%s\n' "$flag"
      fi
    }

    mapfile -t UE_EXTRA_ARGS < <(maybe_force_allocator_args "$@" || true)

    UE_PKG_ROOT="$(cd "$(dirname "''${BASH_SOURCE[0]}")/.." && pwd)"

    cache_home="''${XDG_CACHE_HOME:-}"
    if [[ -z "$cache_home" ]]; then
      cache_home="''${HOME:-}"
      if [[ -z "$cache_home" ]]; then
        echo "ERROR: HOME is not set; cannot determine cache directory for store overlay." >&2
        exit 1
      fi
      cache_home="$cache_home/.cache"
    fi

    maybe_force_vulkan_present_mode_args() {
      # UE supports selecting Vulkan present mode via:
      #   -vulkanpresentmode=<VkPresentModeKHR enum integer>
      #
      # Wrapper override:
      #   UE_VULKAN_PRESENT_MODE=auto|fifo|mailbox|immediate|none
      #
      # Default (auto):
      #   - On NVIDIA: prefer FIFO (vsync) to reduce the risk of GPU hangs (Xid 109)
      #   - Otherwise: keep UE default selection
      local mode
      mode="''${UE_VULKAN_PRESENT_MODE:-auto}"
      case "$mode" in
        auto|fifo|mailbox|immediate|none) ;;
        *)
          mode="auto"
          ;;
      esac

      # Respect explicit user choice.
      local arg
      for arg in "$@"; do
        case "$arg" in
          *vulkanpresentmode=*)
            return 0
            ;;
        esac
      done

      local present_mode
      present_mode=""
      case "$mode" in
        none) present_mode="" ;;
        fifo) present_mode="2" ;;      # VK_PRESENT_MODE_FIFO_KHR
        mailbox) present_mode="1" ;;   # VK_PRESENT_MODE_MAILBOX_KHR
        immediate) present_mode="0" ;; # VK_PRESENT_MODE_IMMEDIATE_KHR
        auto)
          if [[ -e /proc/driver/nvidia/version ]]; then
            present_mode="2"
          fi
          ;;
      esac

      if [[ -n "$present_mode" ]]; then
        echo "UE Vulkan: forcing present mode (-vulkanpresentmode=$present_mode) (UE_VULKAN_PRESENT_MODE=$mode)" >&2
        printf '%s\n' "-vulkanpresentmode=$present_mode"
      fi
    }

    mapfile -t UE_VULKAN_PRESENT_ARGS < <(maybe_force_vulkan_present_mode_args "$@" || true)

    maybe_force_cvarsini_args() {
      # UE supports overriding startup console variables via:
      #   -cvarsini=/path/to/file.ini
      #
      # We use this to apply runtime workarounds without rebuilding the engine.
      #
      # Wrapper knobs:
      #   UE_VULKAN_TIMELINE_SEMAPHORES=auto|on|off|none
      #     - default auto: on NVIDIA -> off (avoid RHISubmissionThread path)
      #
      #   UE_CEF_GPU_ACCELERATION=auto|on|off|none
      #     - default auto: on NVIDIA Open Kernel Module -> off (avoid CEF GPU-process churn)
      #
      #   UE_GPU_SAFE_MODE=auto|on|off|none
      #     - default auto: on NVIDIA Open Kernel Module -> on (avoid Xid 109 / device lost)
      #
      # IMPORTANT: Respect a user-provided -cvarsini=...

      local arg
      for arg in "$@"; do
        case "$arg" in
          -cvarsini=*)
            return 0
            ;;
        esac
      done

      local want_file
      want_file=0

      local -a cvars_lines
      cvars_lines=()

      # Vulkan timeline semaphores
      local timeline_mode
      timeline_mode="''${UE_VULKAN_TIMELINE_SEMAPHORES:-auto}"
      case "$timeline_mode" in
        auto|on|off|none) ;;
        *) timeline_mode="auto" ;;
      esac
      if [[ "$timeline_mode" == "auto" && -e /proc/driver/nvidia/version ]]; then
        timeline_mode="off"
      fi
      if [[ "$timeline_mode" == "off" ]]; then
        want_file=1
        cvars_lines+=("r.Vulkan.Submission.AllowTimelineSemaphores=0")
      fi

      # CEF GPU acceleration (affects embedded browser UI; not UE's Vulkan RHI)
      local cef_mode
      cef_mode="''${UE_CEF_GPU_ACCELERATION:-auto}"
      case "$cef_mode" in
        auto|on|off|none) ;;
        *) cef_mode="auto" ;;
      esac
      if [[ "$cef_mode" == "auto" ]]; then
        if [[ -e /proc/driver/nvidia/version ]] && grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
          cef_mode="off"
        else
          cef_mode="none"
        fi
      fi
      case "$cef_mode" in
        on)
          want_file=1
          cvars_lines+=("r.CEFGPUAcceleration=1")
          ;;
        off)
          want_file=1
          cvars_lines+=("r.CEFGPUAcceleration=0")
          ;;
      esac

      # GPU stability mode (keep GPU rendering on; reduce risky rendering features)
      #
      # Observed on this machine/driver:
      # - Kernel: `NVRM: Xid 109 ... CTX SWITCH TIMEOUT`
      # - UE log: `VK_ERROR_DEVICE_LOST` with active GPU breadcrumb in
      #   `Shadow.Virtual.ProcessInvalidations`
      #
      # Primary mitigation: disable Virtual Shadow Maps (VSM).
      local gpu_safe_mode
      gpu_safe_mode="''${UE_GPU_SAFE_MODE:-auto}"
      case "$gpu_safe_mode" in
        auto|on|off|none) ;;
        *) gpu_safe_mode="auto" ;;
      esac
      if [[ "$gpu_safe_mode" == "auto" ]]; then
        if [[ -e /proc/driver/nvidia/version ]] && grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
          gpu_safe_mode="on"
        else
          gpu_safe_mode="none"
        fi
      fi
      if [[ "$gpu_safe_mode" == "on" ]]; then
        want_file=1
        cvars_lines+=("r.Shadow.Virtual.Enable=0")
      fi

      if [[ "$want_file" != 1 ]]; then
        return 0
      fi

      local cvars_dir cvars_file
      cvars_dir="$cache_home/unreal-engine/wrapper"
      mkdir -p "$cvars_dir"
      cvars_file="$cvars_dir/wrapper-cvars.ini"

      {
        echo "[Startup]"
        printf '%s\n' "''${cvars_lines[@]}"
      } >"$cvars_file"

      if [[ "$timeline_mode" == "off" ]]; then
        echo "UE Vulkan: disabling timeline semaphores via -cvarsini=$cvars_file (UE_VULKAN_TIMELINE_SEMAPHORES=$timeline_mode)" >&2
      fi
      if [[ "$cef_mode" == "off" || "$cef_mode" == "on" ]]; then
        echo "UE CEF: setting r.CEFGPUAcceleration via -cvarsini=$cvars_file (UE_CEF_GPU_ACCELERATION=$cef_mode)" >&2
      fi
      if [[ "$gpu_safe_mode" == "on" ]]; then
        echo "UE GPU: applying safe-mode CVars via -cvarsini=$cvars_file (UE_GPU_SAFE_MODE=$gpu_safe_mode)" >&2
      fi

      printf '%s\n' "-cvarsini=$cvars_file"
    }

    mapfile -t UE_CVARS_ARGS < <(maybe_force_cvarsini_args "$@" || true)

    cleanup_cef_singletons() {
      local config_home tmp_dir have_ss cleanup_mode
      config_home="''${XDG_CONFIG_HOME:-$HOME/.config}"
      tmp_dir="''${TMPDIR:-/tmp}"

      have_ss=0
      if command -v ss >/dev/null 2>&1; then
        have_ss=1
      fi

      cleanup_mode="''${UE_CEF_CLEANUP_MODE:-aggressive}"
      case "$cleanup_mode" in
        aggressive|safe|force|none) ;;
        *)
          cleanup_mode="aggressive"
          ;;
      esac

      if [[ "$cleanup_mode" == "none" ]]; then
        return 0
      fi

      # Avoid a repeatable libcef crash (SIGTRAP) in ProcessSingleton when stale
      # Chromium singleton state exists from a previous UE run.
      #
      # Symptoms in coredumpctl:
      #   ImmediateCrash (libcef.so) -> ProcessSingleton::NotifyOtherProcessOrCreate
      #
      # Fix: remove stale singleton lock/cookie/socket state when it is not active.
      if [[ "$have_ss" == 1 ]]; then
        shopt -s nullglob
        for dir in "$tmp_dir"/.org.chromium.Chromium.*; do
          [[ -d "$dir" ]] || continue
          if [[ "$cleanup_mode" != "force" ]] && ss -xl 2>/dev/null | grep -F -q "$dir/SingletonSocket"; then
            continue
          fi
          rm -rf "$dir" || true
        done
      fi

      shopt -s nullglob
      for wc in "$config_home"/Epic/UnrealEngine/*/Saved/webcache*; do
        [[ -d "$wc" ]] || continue

        local in_use socket_target socket_dir socket_path has_singleton
        in_use=0
        has_singleton=0

        local -a singleton_files
        singleton_files=("$wc"/Singleton*)
        if (( "''${#singleton_files[@]}" > 0 )); then
          has_singleton=1
        fi

        if [[ -L "$wc/SingletonSocket" ]]; then
          socket_target="$(readlink "$wc/SingletonSocket" || true)"
          if [[ "$socket_target" == "$tmp_dir"/.org.chromium.Chromium.*/* ]]; then
            socket_dir="$(dirname "$socket_target")"
            socket_path="$socket_dir/SingletonSocket"
            if [[ "$have_ss" == 1 ]] && ss -xl 2>/dev/null | grep -F -q "$socket_path"; then
              in_use=1
            else
              if [[ "$have_ss" == 1 ]]; then
                rm -rf "$socket_dir" || true
              fi
            fi
          fi
        fi
        if [[ -S "$wc/SingletonSocket" ]]; then
          socket_path="$wc/SingletonSocket"
          if [[ "$have_ss" == 1 ]] && ss -xl 2>/dev/null | grep -F -q "$socket_path"; then
            in_use=1
          fi
        fi

        # "Aggressive" mode: if Chromium singleton artifacts exist, delete the
        # entire UE CEF webcache dir to guarantee no stale ProcessSingleton state
        # survives across launches (prevents libcef ImmediateCrash/SIGTRAP).
        if [[ "$has_singleton" == 1 && ( "$cleanup_mode" == "aggressive" || "$cleanup_mode" == "force" ) ]]; then
          if [[ "$in_use" == 1 && "$cleanup_mode" != "force" ]]; then
            echo "UE CEF cleanup: webcache appears in use; not deleting: $wc" >&2
          else
            echo "UE CEF cleanup: deleting webcache dir due to Singleton* artifacts: $wc" >&2
            rm -rf "$wc" || true
          fi
          continue
        fi

        if [[ "$in_use" == 0 ]]; then
          if (( "''${#singleton_files[@]}" > 0 )); then
            rm -f "''${singleton_files[@]}" || true
          fi
        fi
      done
    }

    cleanup_cef_singletons || true

    # The packaged installed build lives under /nix/store, which is read-only.
    # At runtime the editor (and UnrealBuildTool QueryTargets) tries to write
    # engine state under:
    #   Engine/Intermediate/TargetInfo.json
    #
    # Fix: create a per-store-path overlay under XDG_CACHE_HOME that:
    #   - symlinks almost everything to the store
    #   - provides writable Engine/Intermediate (+ Engine/Saved, Engine/DerivedDataCache)
    #   - runs a *copied* UnrealEditor binary so /proc/self/exe resolves to the overlay,
    #     not the store, making the engine root writable from UE's perspective.
    engine_store_engine_dir="$(readlink -f "$UE_PKG_ROOT/Engine")"
    if [[ -z "$engine_store_engine_dir" || ! -d "$engine_store_engine_dir" ]]; then
      echo "ERROR: Failed to resolve Engine dir under UE_PKG_ROOT=$UE_PKG_ROOT" >&2
      exit 1
    fi

    engine_store_root="$(cd "$engine_store_engine_dir/.." && pwd)"
    overlay_root="$cache_home/unreal-engine/store-overlay/$(basename "$engine_store_root")"

    mkdir -p "$overlay_root"

    if [[ ! -e "$overlay_root/.prepared" ]]; then
      # Top-level dirs in the installed build.
      if [[ -e "$engine_store_root/FeaturePacks" && ! -e "$overlay_root/FeaturePacks" ]]; then
        ln -s "$engine_store_root/FeaturePacks" "$overlay_root/FeaturePacks"
      fi
      if [[ -e "$engine_store_root/Templates" && ! -e "$overlay_root/Templates" ]]; then
        ln -s "$engine_store_root/Templates" "$overlay_root/Templates"
      fi

      mkdir -p "$overlay_root/Engine"

      # Engine/Intermediate must be writable (QueryTargets writes TargetInfo.json here).
      mkdir -p "$overlay_root/Engine/Intermediate"

      # UE may create logs/temp state under Engine/Saved; avoid any /nix/store writes.
      mkdir -p "$overlay_root/Engine/Saved"

      # Some workflows still expect an Engine-local DDC; allow it (default DDC is user dir anyway).
      mkdir -p "$overlay_root/Engine/DerivedDataCache"

      # Populate Engine/* as symlinks, except directories we intentionally override.
      for entry in "$engine_store_root/Engine"/*; do
        name="$(basename "$entry")"
        case "$name" in
          Intermediate|Saved|DerivedDataCache)
            # Writable in the overlay.
            ;;
          Binaries)
            mkdir -p "$overlay_root/Engine/Binaries"
            # We only need to override one file (UnrealEditor) so that /proc/self/exe
            # points into the overlay. To keep this cheap, we symlink top-level entries
            # and only copy UnrealEditor.
            mkdir -p "$overlay_root/Engine/Binaries/Linux"
            for le in "$engine_store_root/Engine/Binaries/Linux"/*; do
              lname="$(basename "$le")"
              if [[ "$lname" == "UnrealEditor" ]]; then
                continue
              fi
              if [[ ! -e "$overlay_root/Engine/Binaries/Linux/$lname" ]]; then
                ln -s "$le" "$overlay_root/Engine/Binaries/Linux/$lname"
              fi
            done

            if [[ ! -x "$overlay_root/Engine/Binaries/Linux/UnrealEditor" ]]; then
              cp -f "$engine_store_root/Engine/Binaries/Linux/UnrealEditor" \
                "$overlay_root/Engine/Binaries/Linux/UnrealEditor"
              chmod +x "$overlay_root/Engine/Binaries/Linux/UnrealEditor"
            fi

            # For other OS/arch dirs under Engine/Binaries, keep symlinks.
            for be in "$engine_store_root/Engine/Binaries"/*; do
              bname="$(basename "$be")"
              if [[ "$bname" == "Linux" ]]; then
                continue
              fi
              if [[ ! -e "$overlay_root/Engine/Binaries/$bname" ]]; then
                ln -s "$be" "$overlay_root/Engine/Binaries/$bname"
              fi
            done
            ;;
          *)
            if [[ ! -e "$overlay_root/Engine/$name" ]]; then
              ln -s "$entry" "$overlay_root/Engine/$name"
            fi
            ;;
        esac
      done

      touch "$overlay_root/.prepared"
    fi

    exec ${unrealFhs}/bin/ue5-fhs -lc 'ulimit -n 16000 || true; UE_ROOT="$1"; shift; cd "$UE_ROOT"; exec "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" "$@"' bash "$overlay_root" "''${UE_EXTRA_ARGS[@]}" "''${UE_VULKAN_PRESENT_ARGS[@]}" "''${UE_CVARS_ARGS[@]}" "$@"
  '';

  desktopEntry = pkgs.runCommand "unreal-engine-desktop-entry" { } ''
    mkdir -p "$out/share/applications"
    install -Dm644 ${./com.unrealengine.UE5Editor.desktop} \
      "$out/share/applications/com.unrealengine.UE5Editor.desktop"
    chmod +x "$out/share/applications/com.unrealengine.UE5Editor.desktop"
  '';

  icon = pkgs.runCommand "unreal-engine-icon" { } ''
    mkdir -p "$out/share/pixmaps"
    install -Dm644 ${./ue5editor.svg} "$out/share/pixmaps/ue5editor.svg"
  '';

  installedDir =
    let
      envInstalled = builtins.getEnv "UE_INSTALLED_DIR";
      envBuiltDir = builtins.getEnv "UE_BUILTDIR";
      envHome = builtins.getEnv "HOME";
      defaultBuiltDir =
        if envBuiltDir != "" then
          envBuiltDir
        else if envHome != "" then
          envHome + "/.cache/unreal-engine/LocalBuilds/Engine"
        else
          ueSrcStr + "/LocalBuilds/Engine";
      defaultInstalledDir = defaultBuiltDir + "/Linux";
      resolved = if envInstalled != "" then envInstalled else defaultInstalledDir;
    in
    toString resolved;

  installedSrcOrNull =
    let
      envInstalledStorePath = builtins.getEnv "UE_INSTALLED_STORE_PATH";
      installedStorePath =
        if envInstalledStorePath != "" then
          toString envInstalledStorePath
        else
          "";
    in
    if installedStorePath != "" then
      if builtins.pathExists installedStorePath then
        builtins.storePath installedStorePath
      else
        null
    else if builtins.pathExists installedDir then
      builtins.path {
        path = installedDir;
        name = "UnrealEngine-installed-linux";
      }
    else
      null;

  installedBuildMissingMessage = ''
    Unreal installed-build tree not found.

    Looked for:
      - UE_INSTALLED_STORE_PATH: $UE_INSTALLED_STORE_PATH
      - UE_INSTALLED_DIR:        ${installedDir}

    Expected a BuildGraph "Make Installed Build Linux" output tree that contains:
      Engine/Binaries/Linux/UnrealEditor

    Produce it via:
      cd pkgs/unreal
      UE_SRC=${ueSrcStr} nix run path:.#unreal-build-installed -- --with-ddc=false

    Then set (optional overrides):
      UE_BUILTDIR=/path/to/BuiltDirectory   (BuildGraph option BuiltDirectory; Linux output is under "$UE_BUILTDIR/Linux")
      UE_INSTALLED_DIR=/path/to/BuiltDirectory/Linux

    Optional optimization (avoids re-importing ~50G from disk each `nix build`):
      UE_INSTALLED_STORE_PATH=/nix/store/...-UnrealEngine-installed-linux
  '';
in
  if !buildInstalled then
    localWrapper
  else
    if installedSrcOrNull == null then
      pkgs.runCommandNoCC "unreal-engine-installed-missing" { } ''
        echo ${lib.escapeShellArg installedBuildMissingMessage} >&2
        exit 1
      ''
    else
      pkgs.symlinkJoin {
        name = "unreal-engine-installed-local-buildgraph-output";
        paths = [
          installedSrcOrNull
          installedUnrealEditor
          desktopEntry
          icon
        ];
      postBuild = ''
        mkdir -p "$out/bin"
        ln -s UnrealEditor "$out/bin/ue5editor"
        ln -s ue5editor "$out/bin/ue5"
        ln -s ue5editor "$out/bin/UE5"
        ln -s ue5editor "$out/bin/unreal-engine-5"
        ln -s ue5editor "$out/bin/unreal-engine-5.sh"
      '';
    }
