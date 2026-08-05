{
  description = "2D Game Engine in Odin with Raylib";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            odin
            ols
            raylib

            # Additional dependencies that might be needed
            glfw
            libGL
            libX11
            libXrandr
            libXinerama
            libXcursor
            libXi

            # Audio backend for vendor:miniaudio (dlopen'd at runtime)
            alsa-lib
          ];

          shellHook = ''
            echo "Odin + Raylib development environment loaded!"
            echo "Odin version: $(odin version)"
            echo ""
            echo "To run a demo:"
            echo "  odin run src/demos/breakout"
          '';

          LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [
            pkgs.raylib
            pkgs.glfw
            pkgs.libGL
            pkgs.libX11
            pkgs.libXrandr
            pkgs.libXinerama
            pkgs.libXcursor
            pkgs.libXi
            pkgs.alsa-lib
          ]}";

          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [
            pkgs.raylib
            pkgs.glfw
            pkgs.libGL
            pkgs.libX11
            pkgs.libXrandr
            pkgs.libXinerama
            pkgs.libXcursor
            pkgs.libXi
            pkgs.alsa-lib
          ]}";
        };
      }
    );
}
