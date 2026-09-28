{
  description = "homgb dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
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

              SDL2
              libGL
              glew
              zlib

              xorg.libX11
              xorg.libXrandr
              xorg.libXinerama
              xorg.libXScrnSaver
              xorg.libXext

              xorg.setxkbmap
              xorg.xkbutils

              git
            ];

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.SDL2
              pkgs.libGL
              pkgs.glew
              pkgs.zlib
              pkgs.xorg.libX11
            ];
          };
        });
    };
}
