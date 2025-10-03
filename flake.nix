{
  description = "Logos Nim SDK with compiled logos-liblogos";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Use local path for development, or switch to github URL for releases:
    logos-liblogos.url = "github:logos-co/logos-liblogos";
    #logos-liblogos.url = "path:/Users/iurimatias/Projects/Logos/LogosCore/logos-liblogos";
  };

  outputs = { self, nixpkgs, logos-liblogos }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        pkgs = import nixpkgs { inherit system; };
        logosLiblogos = logos-liblogos.packages.${system}.default;
      });
    in
    {
      packages = forAllSystems ({ pkgs, logosLiblogos }: {
        default = pkgs.stdenv.mkDerivation rec {
          pname = "logos-nim-sdk";
          version = "1.0.0";
          
          src = ./.;
          
          nativeBuildInputs = [ 
            pkgs.nim
          ];
          
          # Skip building for now - we'll handle Nim compilation separately
          dontBuild = true;
          
          installPhase = ''
            # Debug: Show what's in the source directory
            echo "Contents of source directory:"
            ls -la
            
            # Create the output directory
            mkdir -p $out
            
            # Copy the Nim SDK files
            cp -r logos_api.nim README.md $out/
            
            # Create lib directory and copy the built logos-liblogos library
            mkdir -p $out/lib
            
            # Copy the library from the built logos-liblogos package
            echo "Using logos-liblogos package: ${logosLiblogos}"
            
            # Copy libraries from the built package
            if [ -d "${logosLiblogos}/lib" ]; then
              cp -r "${logosLiblogos}/lib"/* $out/lib/
              echo "Copied libraries from ${logosLiblogos}/lib"
            fi
            
            # Copy binaries if available
            if [ -d "${logosLiblogos}/bin" ]; then
              mkdir -p $out/bin
              cp -r "${logosLiblogos}/bin"/* $out/bin/
              echo "Copied binaries from ${logosLiblogos}/bin"
            fi
            
            # Copy headers if available
            if [ -d "${logosLiblogos}/include" ]; then
              mkdir -p $out/include
              cp -r "${logosLiblogos}/include"/* $out/include/
              echo "Copied headers from ${logosLiblogos}/include"
            fi
          '';
          
          meta = with pkgs.lib; {
            description = "Logos Nim SDK with compiled logos-liblogos";
            platforms = platforms.unix;
            maintainers = [ ];
          };
        };
      });

      devShells = forAllSystems ({ pkgs, logosLiblogos }: {
        default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.nim
            pkgs.nimlangserver
          ];
          
          shellHook = ''
            echo "🔧 Logos Nim SDK Development Environment"
            echo "📦 Nim version: $(nim --version | head -n1)"
            echo ""
            echo "Available commands:"
            echo "  nim c <file>     - Compile Nim programs"
            echo "  nix build        - Build the SDK with logos-liblogos"
          '';
        };
      });
    };
}

