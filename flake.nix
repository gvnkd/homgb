{
  description = "homgb dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      hsOverlay = import ./nix/overlay.nix;
    in
    {
      # nix build / nix run . — and on any NixOS system:
      #   nix run github:gvnkd/homgb
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ hsOverlay ];
          };
          homgb = pkgs.haskellPackages.callCabal2nix "homgb" ./. { };
        in
        {
          inherit homgb;
          default = homgb;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/homgb";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              ghc
              cabal-install
              haskellPackages.haskell-language-server
              pkg-config
              gcc

              sdl3
              # sdl3.pc Requires.private (pkg-config at configure time)
              alsa-lib
              libjack2
              pipewire
              libpulseaudio
              xorg.libXcursor
              xorg.libXi
              xorg.libXfixes
              xorg.libXtst
              libdrm
              mesa
              libgbm
              libxkbcommon
              wayland
              wayland-protocols
              libdecor
              libusb1
              libdecor
              libusb1

              libGL
              glew
              zlib

              xorg.libX11
              xorg.libXrandr
              xorg.libXinerama
              xorg.libXScrnSaver
              xorg.libXext
              xorg.libxcb
              xorg.libXdmcp

              xorg.setxkbmap
              xorg.xkbutils

              # notification daemon testing (see .opencode/MEMORIES.md)
              xdotool
              imagemagick
              flameshot
              xorg.xprop
              xorg.xwininfo
              libnotify
              dbus

              git
              wayland-utils
            ];

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.sdl3
              pkgs.libGL
              pkgs.glew
              pkgs.zlib
              pkgs.xorg.libX11
              pkgs.xorg.libxcb
            ];
          };
        });
    };
}
