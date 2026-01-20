{
  description = "Unreal Engine 5 (dev environment + packaging experiments)";

  # Pinned nixpkgs for reproducible devShells / wrappers.
  # If GitHub access is unreliable, you can temporarily switch this to a local
  # `path:/nix/store/.../nixos` snapshot (system channels) and re-lock.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      # NOTE: UE's own Setup scripts install a bundled toolchain + dotnet runtime
      # (see `Engine/Build/BatchFiles/Linux/Setup.sh` + `SetupToolchain.sh`).
      # We intentionally avoid pulling heavyweight toolchains from nixpkgs here.
      deps = with pkgs; [
        openssl
        zlib
      ];

      tools = with pkgs; [
        bash
        coreutils
        findutils
        gnugrep
        gawk
        gnused
        which
        git
        curl
        wget
        gnutar
        gzip
        python3
        cmake
        ninja
        gnumake
        unzip
        zip
        rsync
        perl
        patchelf
      ];

      unrealFhs = pkgs.buildFHSEnv {
        name = "ue5-fhs";

        targetPkgs = pkgs:
          tools
          ++ deps
          ++ (with pkgs; [
            udev
            alsa-lib
            icu
            SDL2
            vulkan-loader
            vulkan-tools
            vulkan-validation-layers
            glib
            libxkbcommon
            nss
            nspr
            atk
            mesa
            dbus
            pango
            cairo
            libpulseaudio
            libGL
            libgbm
            expat
            libdrm
            wayland
          ])
          ++ (with pkgs.xorg; [
            libICE
            libSM
            libX11
            libxcb
            libXcomposite
            libXcursor
            libXdamage
            libXext
            libXfixes
            libXi
            libXrandr
            libXrender
            libXScrnSaver
            libxshmfence
            libXtst
          ]);

        runScript = "bash";

        # For non-FHS processes that rely on nix-ld.
        NIX_LD_LIBRARY_PATH = lib.makeLibraryPath deps;
        NIX_LD = "${pkgs.stdenv.cc.libc_bin}/bin/ld.so";
        nativeBuildInputs = deps;
      };

      # NOTE: If you run flake commands from inside a git checkout, Nix defaults
      # to `git+file://...` and excludes untracked files from the flake source.
      # Since this repo often has new/untracked files under `pkgs/unreal/`,
      # we provide a clearer error than "path ... does not exist".
      requiredFiles = [
        ./package.nix
        ./com.unrealengine.UE5Editor.desktop
        ./ue5editor.svg
      ];

      missingFiles = builtins.filter (p: !(builtins.pathExists p)) requiredFiles;
      missingFilesList =
        builtins.concatStringsSep "\n  - " (map (p: toString p) missingFiles);

      ensureRequiredFiles =
        if missingFiles == [] then
          null
        else
          throw ''
            Unreal flake: required files are missing from the flake source:
              - ${missingFilesList}

            This usually happens when using an implicit `git+file://` flake URL,
            which excludes untracked files from the source.

            Fix:
              - Use a `path:` flake reference (includes untracked files):
                  cd pkgs/unreal && nix flake show path:.
                  cd pkgs/unreal && nix run path:.#unreal-fhs
              - Or commit / `git add` the missing files.
          '';

      unrealEngine =
        builtins.seq ensureRequiredFiles (import ./package.nix { inherit pkgs unrealFhs; });
      unrealEngineInstalled =
        builtins.seq ensureRequiredFiles (import ./package.nix {
          inherit pkgs unrealFhs;
          buildInstalled = true;
        });

      unrealBuildInstalled = pkgs.writeShellScriptBin "unreal-build-installed" ''
          set -euo pipefail

          usage() {
            cat <<'EOF'
          Usage:
            unreal-build-installed [--with-ddc=(true|false)] [--built-dir=PATH]

          Environment:
            UE_SRC           Path to the UE source tree (default: ~/projects/dev/cpp/UnrealEngine)
            UE_BUILTDIR      BuildGraph "BuiltDirectory" (default: $HOME/.cache/unreal-engine/LocalBuilds/Engine)

          Notes:
            - Runs inside the flake-provided FHS environment (fixes /bin/bash shebangs on NixOS).
            - Mirrors AUR PKGBUILD BuildGraph invocation ("Make Installed Build Linux").
            - We force `WithLinuxArm64=false` to avoid spending hours building AArch64 artifacts on x86_64 hosts.
            - The BuildGraph XML does not accept a "SavedOutput" override; expect writes under "$UE_SRC/Engine/Saved".
          EOF
          }

          if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
            usage
            exit 0
          fi

          with_ddc="false"
          for arg in "$@"; do
            case "$arg" in
              --with-ddc=*)
                with_ddc="''${arg#--with-ddc=}"
                ;;
              --built-dir=*)
                export UE_BUILTDIR="''${arg#--built-dir=}"
                ;;
              *)
                echo "Unknown argument: $arg" >&2
                usage >&2
                exit 2
                ;;
            esac
          done

          export UE_SRC="''${UE_SRC:-/home/vitalyr/projects/dev/cpp/UnrealEngine}"
          export UE_BUILTDIR="''${UE_BUILTDIR:-$HOME/.cache/unreal-engine/LocalBuilds/Engine}"
          export WITH_DDC="$with_ddc"

          case "$with_ddc" in
            true|false) ;;
            *)
              echo "Invalid --with-ddc value: $with_ddc (expected true/false)" >&2
              exit 2
              ;;
          esac

          mkdir -p "$UE_BUILTDIR"

          export DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER=0

          echo "UE_SRC=$UE_SRC"
          echo "UE_BUILTDIR=$UE_BUILTDIR"
          echo "WithDDC=$WITH_DDC"

          exec ${unrealFhs}/bin/ue5-fhs -lc '
            set -euo pipefail
            ulimit -n 16000 || true
            cd "$UE_SRC"

            if [[ ! -x ./Engine/Build/BatchFiles/RunUAT.sh ]]; then
              echo "ERROR: RunUAT.sh not found under UE_SRC=$UE_SRC" >&2
              exit 1
            fi

            cmd=(
              ./Engine/Build/BatchFiles/RunUAT.sh
              BuildGraph
              -target="Make Installed Build Linux"
              -script=Engine/Build/InstalledEngineBuild.xml
              -set:BuiltDirectory="$UE_BUILTDIR"
              -set:WithDDC="$WITH_DDC"
              -set:HostPlatformOnly=false
              -set:WithLinux=true
              -set:WithLinuxArm64=false
              -set:WithWin64=true
              -set:WithMac=false
              -set:WithAndroid=false
              -set:WithIOS=false
              -set:WithTVOS=false
            )

            printf "Running: %q " "''${cmd[@]}"
            echo
            "''${cmd[@]}"
          '
        '';

      unrealPackageInstalled = pkgs.writeShellScriptBin "unreal-package-installed" ''
        set -euo pipefail

        usage() {
          cat <<'EOF'
        Usage:
          unreal-package-installed [--out-link=NAME|--out-link NAME] [--installed-dir=PATH|--installed-dir PATH]

        Purpose:
          - Adds a BuildGraph "installed build" directory to the Nix store (once),
            then builds the flake's `unreal-engine-installed` wrapper package.

        Options:
          --out-link=NAME       Name/path for the build result symlink (default: result-installed)
          --installed-dir=PATH  Installed-build tree dir (default: $UE_INSTALLED_DIR or $UE_BUILTDIR/Linux)

        Environment:
          UE_INSTALLED_STORE_PATH  If set to an existing /nix/store/...-UnrealEngine-installed-linux,
                                   skips the import step and reuses it.
          UE_BUILTDIR              BuildGraph "BuiltDirectory" (default: $HOME/.cache/unreal-engine/LocalBuilds/Engine)
          UE_INSTALLED_DIR         Installed-build tree dir (default: $UE_BUILTDIR/Linux)
          XDG_CACHE_HOME           Used for caching UE_INSTALLED_STORE_PATH (fallback: $HOME/.cache)

        Notes:
          - Importing a full installed build can take a long time and add tens of GB to /nix/store.
          - We cache the last successful UE_INSTALLED_STORE_PATH in:
              $XDG_CACHE_HOME/unreal-engine/UE_INSTALLED_STORE_PATH
          - Build the installed build first via:
              UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build-installed -- --with-ddc=false
        EOF
        }

        if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
          usage
          exit 0
        fi

        out_link="result-installed"
        installed_dir=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --out-link=*)
              out_link="''${1#--out-link=}"
              shift
              ;;
            --out-link)
              if [[ -z "''${2:-}" ]]; then
                echo "ERROR: --out-link requires a value" >&2
                exit 2
              fi
              out_link="$2"
              shift 2
              ;;
            --installed-dir=*)
              installed_dir="''${1#--installed-dir=}"
              shift
              ;;
            --installed-dir)
              if [[ -z "''${2:-}" ]]; then
                echo "ERROR: --installed-dir requires a value" >&2
                exit 2
              fi
              installed_dir="$2"
              shift 2
              ;;
            *)
              echo "Unknown argument: $1" >&2
              usage >&2
              exit 2
              ;;
          esac
        done

        if [[ -z "$installed_dir" ]]; then
          UE_BUILTDIR="''${UE_BUILTDIR:-$HOME/.cache/unreal-engine/LocalBuilds/Engine}"
          installed_dir="''${UE_INSTALLED_DIR:-$UE_BUILTDIR/Linux}"
        fi

        # Avoid broken mirrors by default (user can override by setting NIX_CONFIG).
        if [[ -z "''${NIX_CONFIG:-}" ]]; then
          export NIX_CONFIG=$'substituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n'
        fi

        flake_ref=${lib.escapeShellArg self.outPath}

        cache_home="''${XDG_CACHE_HOME:-$HOME/.cache}"
        cache_dir="$cache_home/unreal-engine"
        cache_file="$cache_dir/UE_INSTALLED_STORE_PATH"

        if [[ -z "''${UE_INSTALLED_STORE_PATH:-}" && -f "$cache_file" ]]; then
          cached="$(head -n 1 "$cache_file" || true)"
          if [[ -n "$cached" && -e "$cached" ]]; then
            export UE_INSTALLED_STORE_PATH="$cached"
          fi
        fi

        if [[ -n "''${UE_INSTALLED_STORE_PATH:-}" ]]; then
          case "$UE_INSTALLED_STORE_PATH" in
            /nix/store/*) ;;
            *)
              echo "ERROR: UE_INSTALLED_STORE_PATH must be a /nix/store path: $UE_INSTALLED_STORE_PATH" >&2
              exit 1
              ;;
          esac
          if [[ ! -e "$UE_INSTALLED_STORE_PATH" ]]; then
            echo "ERROR: UE_INSTALLED_STORE_PATH does not exist: $UE_INSTALLED_STORE_PATH" >&2
            exit 1
          fi
          store_path="$UE_INSTALLED_STORE_PATH"
          echo "Reusing UE_INSTALLED_STORE_PATH=$store_path" >&2
        else
          if [[ ! -x "$installed_dir/Engine/Binaries/Linux/UnrealEditor" ]]; then
            echo "ERROR: installed-build tree not found: $installed_dir" >&2
            echo "Expected: $installed_dir/Engine/Binaries/Linux/UnrealEditor" >&2
            exit 1
          fi
          echo "Adding installed build to the Nix store (this can take a while): $installed_dir" >&2
          store_path="$(nix store add-path --name UnrealEngine-installed-linux "$installed_dir")"
          echo "Added store path: $store_path" >&2
        fi

        mkdir -p "$cache_dir"
        printf '%s\n' "$store_path" > "$cache_file"
        echo "Cached UE_INSTALLED_STORE_PATH in: $cache_file" >&2

        echo "Building flake package: $flake_ref#unreal-engine-installed" >&2
        exec env UE_INSTALLED_STORE_PATH="$store_path" nix build "$flake_ref#unreal-engine-installed" --impure -L --out-link "$out_link"
      '';

      unrealSetup = pkgs.writeShellScriptBin "unreal-setup" ''
        set -euo pipefail

        export UE_SRC="''${UE_SRC:-/home/vitalyr/projects/dev/cpp/UnrealEngine}"

        if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
          cat <<'EOF'
        Usage:
          UE_SRC=/abs/path/to/UnrealEngine nix run path:.#unreal-setup -- [Setup.sh args...]

        Notes:
          - Runs `Setup.sh` inside the flake's FHS environment (fixes `/bin/bash` shebangs on NixOS).
          - By default, this wrapper avoids overwriting `.git/hooks/*` (sets `GIT_DIR=/dev/null`).
            Set `UE_SETUP_ALLOW_GIT_HOOKS=1` to let `Setup.sh` register hooks.

        Examples:
          UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-setup -- --force
          UE_GITDEPS_ARGS="--exclude=Win64 --exclude=Mac" UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-setup -- --force
        EOF
          exit 0
        fi

        # Matches the AUR wrapper workaround; harmless for other operations.
        export DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER=0

        exec ${unrealFhs}/bin/ue5-fhs -lc '
          set -euo pipefail
          ulimit -n 16000 || true
          UE_SRC="$1"; shift

          # Avoid overwriting `.git/hooks/*` by default. Opt-in via:
          #   UE_SETUP_ALLOW_GIT_HOOKS=1
          if [[ "''${UE_SETUP_ALLOW_GIT_HOOKS:-0}" != "1" ]]; then
            export GIT_DIR=/dev/null
          fi

          cd "$UE_SRC"
          exec ./Setup.sh "$@"
        ' bash "$UE_SRC" "$@"
      '';

      unrealGenerateProjectFiles = pkgs.writeShellScriptBin "unreal-generate-project-files" ''
        set -euo pipefail

        export UE_SRC="''${UE_SRC:-/home/vitalyr/projects/dev/cpp/UnrealEngine}"

        if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
          cat <<'EOF'
        Usage:
          UE_SRC=/abs/path/to/UnrealEngine nix run path:.#unreal-generate-project-files -- [GenerateProjectFiles.sh args...]

        Notes:
          - Runs `GenerateProjectFiles.sh` inside the flake's FHS environment (fixes `/bin/bash` shebangs on NixOS).
        EOF
          exit 0
        fi

        exec ${unrealFhs}/bin/ue5-fhs -lc '
          set -euo pipefail
          ulimit -n 16000 || true
          UE_SRC="$1"; shift
          cd "$UE_SRC"
          exec ./GenerateProjectFiles.sh "$@"
        ' bash "$UE_SRC" "$@"
      '';

      unrealBuild = pkgs.writeShellScriptBin "unreal-build" ''
        set -euo pipefail

        export UE_SRC="''${UE_SRC:-/home/vitalyr/projects/dev/cpp/UnrealEngine}"

        if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" || $# -eq 0 ]]; then
          cat <<'EOF'
        Usage:
          UE_SRC=/abs/path/to/UnrealEngine nix run path:.#unreal-build -- <Target> <Platform> <Configuration> [Build.sh args...]

        Examples:
          UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- UnrealEditor Linux Development -Progress
          UE_SRC=~/projects/dev/cpp/UnrealEngine nix run path:.#unreal-build -- ShaderCompileWorker Linux Development -Progress
        EOF
          exit 0
        fi

        exec ${unrealFhs}/bin/ue5-fhs -lc '
          set -euo pipefail
          ulimit -n 16000 || true
          UE_SRC="$1"; shift
          cd "$UE_SRC"
          exec ./Engine/Build/BatchFiles/Linux/Build.sh "$@"
        ' bash "$UE_SRC" "$@"
      '';

      unrealEditorInstalledDir = pkgs.writeShellScriptBin "unreal-editor-installed-dir" ''
        set -euo pipefail

        if [[ "$(id -u)" -eq 0 ]]; then
          echo "ERROR: Run this as an unprivileged user; not as root." >&2
          exit 1
        fi

        if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
          cat <<'EOF'
        Usage:
          UE_INSTALLED_DIR=/abs/path/to/LocalBuilds/Engine/Linux nix run path:.#unreal-editor-installed-dir -- [UnrealEditor args...]

        Environment:
          UE_INSTALLED_DIR   Installed-build tree dir (default: $UE_BUILTDIR/Linux)
          UE_BUILTDIR        BuildGraph "BuiltDirectory" (default: $HOME/.cache/unreal-engine/LocalBuilds/Engine)

        Notes:
          - Runs the installed build directly (no Nix store packaging/import).
          - Uses the flake FHS environment to satisfy `/bin/bash` shebangs + runtime libs.
        EOF
          exit 0
        fi

        UE_BUILTDIR="''${UE_BUILTDIR:-$HOME/.cache/unreal-engine/LocalBuilds/Engine}"
        UE_ROOT="''${UE_INSTALLED_DIR:-$UE_BUILTDIR/Linux}"

        if [[ ! -x "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" ]]; then
          echo "ERROR: UnrealEditor not found under UE_INSTALLED_DIR=$UE_ROOT" >&2
          echo "Expected: $UE_ROOT/Engine/Binaries/Linux/UnrealEditor" >&2
          exit 1
        fi

        exec ${unrealFhs}/bin/ue5-fhs -lc '
          set -euo pipefail
          ulimit -n 16000 || true
          UE_ROOT="$1"; shift
          cd "$UE_ROOT"
          exec "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" "$@"
        ' bash "$UE_ROOT" "$@"
      '';
    in
    {
      devShells.${system} = {
        default = unrealFhs.env;
      };

      packages.${system} = {
        unreal-fhs = unrealFhs;
        unreal-package-installed = unrealPackageInstalled;
        unreal-setup = unrealSetup;
        unreal-generate-project-files = unrealGenerateProjectFiles;
        unreal-build = unrealBuild;
        unreal-editor-installed-dir = unrealEditorInstalledDir;
        unreal-engine = unrealEngine;
        unreal-engine-installed = unrealEngineInstalled;
        default = unrealEngine;
      };

      apps.${system} = {
        unreal-fhs = {
          type = "app";
          program = "${unrealFhs}/bin/ue5-fhs";
        };

        unreal-build-installed = {
          type = "app";
          program = "${unrealBuildInstalled}/bin/unreal-build-installed";
        };

        unreal-package-installed = {
          type = "app";
          program = "${unrealPackageInstalled}/bin/unreal-package-installed";
        };

        unreal-setup = {
          type = "app";
          program = "${unrealSetup}/bin/unreal-setup";
        };

        unreal-generate-project-files = {
          type = "app";
          program = "${unrealGenerateProjectFiles}/bin/unreal-generate-project-files";
        };

        unreal-build = {
          type = "app";
          program = "${unrealBuild}/bin/unreal-build";
        };

        unreal-editor-installed-dir = {
          type = "app";
          program = "${unrealEditorInstalledDir}/bin/unreal-editor-installed-dir";
        };

        unreal-editor = {
          type = "app";
          program = "${unrealEngine}/bin/UnrealEditor";
        };

        unreal-editor-installed = {
          type = "app";
          program = "${unrealEngineInstalled}/bin/UnrealEditor";
        };
      };
    };
}
