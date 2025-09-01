{ pkgs ? import <nixpkgs> {} }: let
  stdenv = pkgs.llvmPackages_18.stdenv;
  dotnetPkg = (with pkgs.dotnetCorePackages; combinePackages [
      sdk_9_0
    ]);
  deps = (with pkgs; [
    zlib
    zlib.dev
    openssl
    dotnetPkg
  ]);
in
(pkgs.buildFHSEnv {
  name = "UnrealEditor";

  targetPkgs = pkgs: (with pkgs;
  [ udev
    alsa-lib
    mono
    dotnet-sdk
    stdenv
    clang_18
    icu
    openssl
    zlib
    SDL2
    SDL2.dev
    SDL2 SDL2_image SDL2_ttf SDL2_mixer
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
    expat
    libdrm
    wayland
  ]) ++ (with pkgs.xorg;
  [ 
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

  # runScript = "zsh";

  NIX_LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath ([
    stdenv
  ] ++ deps);
  NIX_LD = "${stdenv.cc.libc_bin}/bin/ld.so";
  nativeBuildInputs = [ 
  ] ++ deps;

  shellHook = ''
    DOTNET_ROOT="${dotnetPkg}";
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1;
  '';
}).env

