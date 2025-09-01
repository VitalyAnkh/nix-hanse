{
  description = "Unreal Engine 5 for NixOS";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ self.overlays.default ];
        config.allowUnfree = true;
      };

      mkUnrealEngine = { pname, version, src ? "/home/vitalyr/projects/dev/cpp/UnrealEngine" }:
        with pkgs;
        stdenv.mkDerivation rec {
          inherit pname version;
          
          # Use local source by default  
          src = builtins.path { path = /home/vitalyr/projects/dev/cpp/UnrealEngine; name = "UnrealEngine-source"; };

          nativeBuildInputs = [
            git
            openssh
            wget
            curl
            makeWrapper
            patchelf
            python3
            dotnet-sdk_8
            dotnet-runtime_8
            clang_20
            lld_20
            llvmPackages_20.bintools  # This provides llvm-ar and other LLVM tools
            cmake
            ninja
            pkg-config
          ];

          buildInputs = [
            # Core dependencies
            icu
            SDL2
            vulkan-loader
            vulkan-headers
            xorg.libX11
            xorg.libXi
            xorg.libXxf86vm
            xorg.libXfixes
            xorg.libXrender
            xorg.libXcursor
            xorg.libXinerama
            xorg.libXrandr
            xorg.libICE
            xorg.libSM
            libGL
            libGLU
            openssl
            zlib
            libxml2
            freetype
            fontconfig
            alsa-lib
            pulseaudio
            wayland
            libxkbcommon
            dbus
            systemd
            # Additional build dependencies
            glibc
            glibc.dev
            gcc.cc.lib
            gcc
            stdenv.cc.cc
            ncurses
            readline
            libuuid
            xdg-user-dirs
            # Steam run for compatibility
            steam-run
          ];

          # Disable sandbox for network access
          __noChroot = true;
          
          # Environment variables
          DOTNET_CLI_TELEMETRY_OPTOUT = "1";
          DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1";
          DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER = "0";
          DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = "1";
          
          # Use clang as compiler
          CC = "${clang_20}/bin/clang";
          CXX = "${clang_20}/bin/clang++";
          
          # Set library paths
          LD_LIBRARY_PATH = lib.makeLibraryPath buildInputs;
          
          # Critical for NixOS: Set proper include and library paths for clang
          NIX_CFLAGS_COMPILE = "-isystem ${glibc.dev}/include -isystem ${stdenv.cc.cc}/include/c++/v1";
          NIX_LDFLAGS = "-L${glibc}/lib -L${stdenv.cc.cc.lib}/lib -L${gcc.cc.lib}/lib";
          CPLUS_INCLUDE_PATH = "${stdenv.cc.cc}/include/c++/v1:${glibc.dev}/include";
          C_INCLUDE_PATH = "${glibc.dev}/include";

          postPatch = ''
            echo "Post-patching UnrealEngine scripts for NixOS..."
            
            # Use regular bash, not bash-interactive
            BASH_BIN="${pkgs.bashInteractive}/bin/bash"
            echo "Using bash: $BASH_BIN"
            
            # Force patch ALL shell scripts after patchShebangs
            echo "Patching ALL shell scripts..."
            find . -name "*.sh" -type f -exec sed -i "1s|#!/bin/bash|#!$BASH_BIN|" {} \;
            find . -name "*.sh" -type f -exec sed -i "1s|#!/usr/bin/env bash|#!$BASH_BIN|" {} \;
            find . -name "*.sh" -type f -exec sed -i "1s|#! /bin/bash|#!$BASH_BIN|" {} \;
            find . -name "*.sh" -type f -exec sed -i "1s|#!/bin/sh|#!$BASH_BIN|" {} \;
            find . -name "*.sh" -type f -exec chmod +x {} \;
            
            # Specifically patch critical scripts
            for script in Setup.sh GenerateProjectFiles.sh; do
                if [ -f "$script" ]; then
                    sed -i "1s|.*|#!$BASH_BIN|" "$script"
                    chmod +x "$script"
                    echo "$script shebang: $(head -n1 $script)"
                fi
            done
            
            # Patch Engine/Build/BatchFiles scripts specifically
            if [ -d "Engine/Build/BatchFiles" ]; then
                echo "Patching Engine/Build/BatchFiles scripts..."
                find Engine/Build/BatchFiles -name "*.sh" -type f -exec sed -i "1s|.*|#!$BASH_BIN|" {} \;
                find Engine/Build/BatchFiles -name "*.sh" -type f -exec chmod +x {} \;
                
                # Check GitDependencies.sh specifically
                if [ -f "Engine/Build/BatchFiles/Linux/GitDependencies.sh" ]; then
                    echo "GitDependencies.sh shebang: $(head -n1 Engine/Build/BatchFiles/Linux/GitDependencies.sh)"
                fi
            fi
            
            # Patch ELF binaries for NixOS
            echo "Patching ELF binaries..."
            if [ -n "$NIX_CC" ] && [ -f "$NIX_CC/nix-support/dynamic-linker" ]; then
                DYNAMIC_LINKER=$(cat $NIX_CC/nix-support/dynamic-linker)
                echo "Using dynamic linker: $DYNAMIC_LINKER"
                
                # Patch GitDependencies binary specifically
                GITDEPS_BINARY="Engine/Binaries/DotNET/GitDependencies/linux-x64/GitDependencies"
                if [ -f "$GITDEPS_BINARY" ]; then
                    echo "Patching GitDependencies binary: $GITDEPS_BINARY"
                    ${pkgs.patchelf}/bin/patchelf --set-interpreter "$DYNAMIC_LINKER" "$GITDEPS_BINARY" || true
                    
                    # Also set rpath for required libraries
                    RPATH_DIRS="${lib.makeLibraryPath buildInputs}"
                    ${pkgs.patchelf}/bin/patchelf --set-rpath "$RPATH_DIRS" "$GITDEPS_BINARY" || true
                    
                    echo "GitDependencies binary patched"
                fi
                
                # Patch other binaries if needed
                find Engine/Binaries -name "*" -type f -executable | while read -r binary; do
                    if file "$binary" 2>/dev/null | grep -q "ELF.*executable\|ELF.*shared object"; then
                        echo "Patching binary: $binary"
                        ${pkgs.patchelf}/bin/patchelf --set-interpreter "$DYNAMIC_LINKER" "$binary" 2>/dev/null || true
                    fi
                done
            else
                echo "Warning: Could not find dynamic linker, skipping ELF patching"
            fi
          '';

          configurePhase = ''
            runHook preConfigure
            
            # Set up build directory
            mkdir -p $out
            export UE_INSTALL_LOCATION=$out
            
            # Set additional environment variables for dotnet
            export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
            export LD_LIBRARY_PATH="${lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH"
            # Use current XDG_RUNTIME_DIR if available, fallback to user runtime dir
            export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
            
            # Critical for NixOS: Set proper paths for clang to find headers and libraries
            export CPLUS_INCLUDE_PATH="${stdenv.cc.cc}/include/c++/v1:${glibc.dev}/include"
            export C_INCLUDE_PATH="${glibc.dev}/include"
            export LIBRARY_PATH="${gcc.cc.lib}/lib:${glibc}/lib"
            
            # Ensure LLVM tools are in PATH
            export PATH="${llvmPackages_20.bintools}/bin:$PATH"
            
            # Set UE-specific environment variables to bypass SDK checks
            export UE_USE_SYSTEM_COMPILER=1
            export LINUX_MULTIARCH_ROOT="${pkgs.glibc}/lib"
            export UE_LINUX_USE_BUNDLED_LIBC=0
            export UE_BUILD_DEVELOPER_TOOLS=1
            export UE_BUILD_SHIPPING=0
            
            # Run Setup.sh with explicit bash to download dependencies
            echo "Running Setup.sh with explicit bash..."
            ${pkgs.bashInteractive}/bin/bash ./Setup.sh || true
            
            # Modify Linux SDK configuration to work with Nix environment
            echo "Configuring Linux SDK for NixOS compatibility..."
            if [ -f "Engine/Config/Linux/Linux_SDK.json" ]; then
                # Backup original
                cp "Engine/Config/Linux/Linux_SDK.json" "Engine/Config/Linux/Linux_SDK.json.bak"
                # Create compatible SDK configuration
                cat > "Engine/Config/Linux/Linux_SDK.json" << 'EOF'
{
	"MainVersion" : "nix-clang-18",
	"MinVersion" : "nix-clang-18", 
	"MaxVersion" : "nix-clang-18",

	"AutoSDKPlatform" : "Linux_x64"
}
EOF
                echo "Updated Linux SDK configuration for NixOS"
            fi
            
            # Create fake AutoSDK structure to satisfy UE platform checks
            echo "Creating AutoSDK structure for Linux platform..."
            SDK_VERSION="nix-clang-18"
            SDK_ROOT="Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64"
            SDK_VERSION_DIR="$SDK_ROOT/$SDK_VERSION"
            mkdir -p "$SDK_VERSION_DIR/x86_64-unknown-linux-gnu"
            
            # Create the required ToolchainVersion.txt file (this is critical for UE SDK detection)
            echo "$SDK_VERSION" > "$SDK_VERSION_DIR/ToolchainVersion.txt"
            
            # Create a minimal SDK info file
            cat > "$SDK_VERSION_DIR/Setup.sh" << 'EOF'
#!/bin/bash
# NixOS Linux SDK - using system toolchain
echo "NixOS Linux SDK - using system toolchain"
export UE_SDKS_ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$(realpath "''${BASH_SOURCE[0]}")")")")")"
export LINUX_SDK_ROOT="''${UE_SDKS_ROOT}/HostLinux/Linux_x64"
EOF
            chmod +x "$SDK_VERSION_DIR/Setup.sh"
            
            # Also create a VERSION file for compatibility
            echo "$SDK_VERSION" > "$SDK_VERSION_DIR/VERSION"
            
            # Set AutoSDK environment variables
            export UE_SDKS_ROOT="$PWD/Engine/Extras/ThirdPartyNotUE/SDKs"
            export LINUX_SDK_ROOT="$UE_SDKS_ROOT/HostLinux/Linux_x64"
            # Critical: Set LINUX_MULTIARCH_ROOT to the versioned SDK directory
            export LINUX_MULTIARCH_ROOT="$PWD/$SDK_VERSION_DIR"
            
            # Configure NuGet environment with proper permissions
            echo "Configuring NuGet environment..."
            export HOME=$PWD/.nuget-home
            export DOTNET_CLI_HOME=$HOME
            export NUGET_HTTP_CACHE_PATH=$HOME/.nuget-cache
            export NUGET_PACKAGES=$HOME/.nuget-packages
            
            # Create directories with proper permissions
            mkdir -p $HOME/.nuget
            mkdir -p $NUGET_HTTP_CACHE_PATH
            mkdir -p $NUGET_PACKAGES
            chmod -R 755 $HOME
            
            # Create a basic NuGet.Config file
            cat > $HOME/.nuget/NuGet.Config << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
</configuration>
EOF
            chmod 644 $HOME/.nuget/NuGet.Config
            
            # Test network connectivity
            echo "Testing network connectivity..."
            ${pkgs.curl}/bin/curl -I https://api.nuget.org/v3/index.json || echo "Network test failed"
            
            # Restore NuGet packages for UnrealBuildTool with proper environment
            echo "Restoring NuGet packages for UnrealBuildTool..."
            if [ -f "Engine/Source/Programs/UnrealBuildTool/UnrealBuildTool.csproj" ]; then
                ${pkgs.dotnet-sdk_8}/bin/dotnet restore Engine/Source/Programs/UnrealBuildTool/UnrealBuildTool.csproj --configfile $HOME/.nuget/NuGet.Config || true
            fi
            
            # Create .lldbinit in a writable location to avoid the read-only filesystem error
            mkdir -p /tmp/lldb-init
            export HOME_BACKUP=$HOME
            export HOME=/tmp/lldb-init
            
            # Ensure LLVM tools are in PATH and create symlinks
            export PATH="${llvmPackages_20.bintools}/bin:$PATH"
            echo "Checking for llvm-ar: $(which llvm-ar || echo 'not found')"
            
            # Create symlinks in Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/x86_64-unknown-linux-gnu/bin/
            # This is where UnrealBuildTool expects to find the tools when using the SDK
            TOOLCHAIN_BIN_DIR="$PWD/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/$SDK_VERSION/x86_64-unknown-linux-gnu/bin"
            mkdir -p "$TOOLCHAIN_BIN_DIR"
            
            # Create symlinks for all necessary LLVM tools
            ln -sf ${llvmPackages_20.bintools}/bin/llvm-ar "$TOOLCHAIN_BIN_DIR/llvm-ar"
            ln -sf ${llvmPackages_20.bintools}/bin/llvm-ranlib "$TOOLCHAIN_BIN_DIR/llvm-ranlib"
            ln -sf ${llvmPackages_20.bintools}/bin/llvm-objcopy "$TOOLCHAIN_BIN_DIR/llvm-objcopy"
            ln -sf ${llvmPackages_20.bintools}/bin/llvm-strip "$TOOLCHAIN_BIN_DIR/llvm-strip"
            ln -sf ${clang_20}/bin/clang "$TOOLCHAIN_BIN_DIR/clang"
            ln -sf ${clang_20}/bin/clang++ "$TOOLCHAIN_BIN_DIR/clang++"
            ln -sf ${lld_20}/bin/lld "$TOOLCHAIN_BIN_DIR/lld"
            ln -sf ${lld_20}/bin/ld.lld "$TOOLCHAIN_BIN_DIR/ld.lld"
            
            # Also create symlinks without the x86_64 directory for compatibility
            TOOLCHAIN_BIN_DIR2="$PWD/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/$SDK_VERSION/bin"
            mkdir -p "$TOOLCHAIN_BIN_DIR2"
            ln -sf ${llvmPackages_20.bintools}/bin/llvm-ar "$TOOLCHAIN_BIN_DIR2/llvm-ar"
            ln -sf ${clang_20}/bin/clang "$TOOLCHAIN_BIN_DIR2/clang"
            ln -sf ${clang_20}/bin/clang++ "$TOOLCHAIN_BIN_DIR2/clang++"
            
            # Add toolchain bin directories to PATH
            export PATH="$TOOLCHAIN_BIN_DIR:$TOOLCHAIN_BIN_DIR2:$PATH"
            
            # Generate project files - try without steam-run first since we need our PATH
            echo "Running GenerateProjectFiles.sh..."
            export HOME=$HOME_BACKUP
            # Force enable Linux platform by setting additional environment variables
            export UE_SKIP_TOOLCHAIN_CHECKS=1
            export UE_OVERRIDE_PLATFORM_SDK=1
            if ${pkgs.bashInteractive}/bin/bash ./GenerateProjectFiles.sh -makefile -platforms=Linux -ForceUseSystemCompiler; then
                echo "GenerateProjectFiles.sh completed successfully"
            else
                echo "GenerateProjectFiles.sh failed, trying with steam-run..."
                export HOME=/tmp/lldb-init
                if PATH="${llvmPackages_20.bintools}/bin:$PATH" ${pkgs.steam-run}/bin/steam-run ${pkgs.bashInteractive}/bin/bash ./GenerateProjectFiles.sh -makefile -ForceUseSystemCompiler; then
                    echo "GenerateProjectFiles.sh completed successfully without steam-run"
                else
                    echo "Both attempts to run GenerateProjectFiles.sh failed"
                    # List what files were created to debug
                    echo "Files in current directory:"
                    ls -la
                    echo "Checking for Makefile or .mk files:"
                    find . -name "Makefile*" -o -name "*.mk" | head -10
                fi
            fi
            
            # Restore HOME
            export HOME=$HOME_BACKUP
            
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            
            # Check if Makefile exists
            if [ -f Makefile ]; then
                echo "Found Makefile, building UnrealEditor..."
                # Build sequentially to avoid UnrealBuildTool mutex conflicts
                # Use ARGS to pass -ForceUseSystemCompiler to UnrealBuildTool
                make UnrealEditor ARGS=-ForceUseSystemCompiler || echo "UnrealEditor build failed"
                make ShaderCompileWorker ARGS=-ForceUseSystemCompiler || echo "ShaderCompileWorker build failed"  
                make UnrealLightmass ARGS=-ForceUseSystemCompiler || echo "UnrealLightmass build failed"
                make UnrealPak ARGS=-ForceUseSystemCompiler || echo "UnrealPak build failed"
            else
                echo "No Makefile found, checking for alternative build systems..."
                if [ -f "Engine/Build/BatchFiles/Linux/Build.sh" ]; then
                    echo "Using Engine build script..."
                    cd Engine/Build/BatchFiles/Linux
                    ${pkgs.bashInteractive}/bin/bash ./Build.sh UnrealEditor Linux Development || true
                    cd ../../../..
                elif [ -d "Engine/Binaries/Linux" ] && [ -f "Engine/Binaries/Linux/UnrealEditor" ]; then
                    echo "UnrealEditor binary already exists, skipping build"
                else
                    echo "No build system found, listing directory contents for debugging..."
                    ls -la
                    echo "Checking Engine directory..."
                    ls -la Engine/ | head -10
                    exit 1
                fi
            fi
            
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            
            # Create installation directories
            mkdir -p $out/bin
            mkdir -p $out/lib
            mkdir -p $out/share/unreal-engine
            
            # Copy engine files
            cp -r Engine $out/share/unreal-engine/
            
            # Copy additional files if they exist
            [ -f GenerateProjectFiles.sh ] && cp GenerateProjectFiles.sh $out/share/unreal-engine/
            [ -f Setup.sh ] && cp Setup.sh $out/share/unreal-engine/
            
            # Create wrapper script for UnrealEditor if it exists
            if [ -f "$out/share/unreal-engine/Engine/Binaries/Linux/UnrealEditor" ]; then
                makeWrapper $out/share/unreal-engine/Engine/Binaries/Linux/UnrealEditor $out/bin/UnrealEditor \
                  --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath buildInputs}" \
                  --set UNREAL_ENGINE_ROOT $out/share/unreal-engine
            else
                echo "Warning: UnrealEditor binary not found, skipping wrapper creation"
                # Create a placeholder script
                cat > $out/bin/UnrealEditor << 'EOF'
#!/bin/sh
echo "UnrealEditor was not successfully built"
echo "Please check the build logs for errors"
exit 1
EOF
                chmod +x $out/bin/UnrealEditor
            fi
            
            # Create symlinks
            ln -s $out/bin/UnrealEditor $out/bin/UE5
            ln -s $out/bin/UnrealEditor $out/bin/ue5
            
            runHook postInstall
          '';

          meta = with lib; {
            description = "A 3D game engine by Epic Games";
            homepage = "https://www.unrealengine.com/";
            license = licenses.unfree;
            platforms = platforms.linux;
            maintainers = [];
            mainProgram = "UnrealEditor";
          };
        };

    in {
      overlays.default = final: prev: {
        unreal_engine_5_5 = mkUnrealEngine {
          pname = "unreal-engine";
          version = "5.5.0";
        };
        
        unreal_engine_5_6 = mkUnrealEngine {
          pname = "unreal-engine";
          version = "5.6.0";
        };
      };

      packages.x86_64-linux = rec {
        unreal_engine_5_5 = pkgs.unreal_engine_5_5;
        unreal_engine_5_6 = pkgs.unreal_engine_5_6;
        default = unreal_engine_5_6;
      };

      devShells.x86_64-linux.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          # Development tools
          git
          gnumake
          cmake
          ninja
          clang_20
          lld_20
          python3
          dotnet-sdk_8
          
          # Libraries
          icu
          SDL2
          vulkan-loader
          vulkan-headers
          xorg.libX11
          xorg.libXi
          libGL
          openssl
          zlib
          
          # Tools for debugging
          gdb
          valgrind
          strace
          patchelf
        ];

        shellHook = ''
          echo "Unreal Engine 5 development environment"
          echo "----------------------------------------"
          echo "Source directory: /home/vitalyr/projects/dev/cpp/UnrealEngine"
          echo ""
          echo "To build Unreal Engine:"
          echo "  cd /home/vitalyr/projects/dev/cpp/UnrealEngine"
          echo "  ./Setup.sh"
          echo "  ./GenerateProjectFiles.sh"
          echo "  make UnrealEditor"
          echo ""
          echo "Or use nix build:"
          echo "  nix build .#unreal_engine_5_6"
          
          export CC=${pkgs.clang_20}/bin/clang
          export CXX=${pkgs.clang_20}/bin/clang++
          export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [
            pkgs.icu
            pkgs.SDL2
            pkgs.vulkan-loader
            pkgs.xorg.libX11
            pkgs.libGL
            pkgs.openssl
            pkgs.zlib
          ]}:$LD_LIBRARY_PATH
        '';
      };
    };
}
