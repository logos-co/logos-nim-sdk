{
  description = "logos-nim-sdk — protocol-native Nim SDK (lp_* consumer over logos-protocol)";

  inputs = {
    # Follow the same nixpkgs as logos-cpp-sdk to ensure Qt compatibility
    nixpkgs.follows = "logos-cpp-sdk/nixpkgs";
    logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";
    logos-liblogos.url = "github:logos-co/logos-liblogos";

    # The SHARED liblogos_protocol carries the lp_* C ABI this SDK dlopens.
    # liblogos_core links the STATIC archive and re-exports no lp_* symbol
    # (measured: zero `_lp_` in its export table on macOS), so the shared build
    # is a separate, required artifact.
    #
    # The `follows` below is load-bearing, not tidiness. An embedded-core
    # process holds BOTH copies of logos-protocol — the shared one this SDK
    # dlopens and the static one inside liblogos_core — and Qt's QMetaType
    # registry is process-global, so two builds registering the same type names
    # is a real hazard. Measured: pinning the shared library independently, at
    # the same MAJOR.MINOR but a different revision, SIGSEGV'd the e2e check on
    # the very first call. One protocol revision, built once, used by both.
    logos-protocol.url = "github:logos-co/logos-protocol";
    logos-liblogos.inputs.logos-protocol.follows = "logos-protocol";

    # Fixture for the end-to-end check: a real module with a method/event
    # matrix. Follows this flake's liblogos so the module and the core in the
    # check are the same generation.
    logos-test-modules.url = "github:logos-co/logos-test-modules";
    logos-test-modules.inputs.logos-liblogos.follows = "logos-liblogos";
  };

  outputs = { self, nixpkgs, logos-cpp-sdk, logos-liblogos, logos-protocol
            , logos-test-modules }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f rec {
        inherit system;
        pkgs = import nixpkgs { inherit system; };
        libExt = if nixpkgs.lib.hasSuffix "darwin" system then "dylib" else "so";
        logosLiblogos = logos-liblogos.packages.${system}.default;
        protocolLib = logos-protocol.packages.${system}.logos-protocol-lib;
        basicModule = logos-test-modules.modules.${system}.test_basic_module.install;
      });
    in
    {
      packages = forAllSystems ({ pkgs, logosLiblogos, protocolLib, libExt, ... }: {
        default = pkgs.stdenv.mkDerivation {
          pname = "logos-nim-sdk";
          version = "2.0.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.nim ];

          # The SDK is source; nothing to compile here. Consumers `import
          # logos_api` (embedded core + consumer) or `import logos_client`
          # (consumer only) and compile against their own program.
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/nim
            cp logos_api.nim logos_client.nim logos_protocol.nim README.md $out/nim/

            # The shared logos-protocol library the SDK dlopens, plus the
            # embedded-core runtime, side by side in one lib/ — which is the
            # layout logos_api.nim probes first when LOGOS_PROTOCOL_LIB is unset.
            mkdir -p $out/lib $out/bin $out/include $out/modules
            cp -r ${logosLiblogos}/lib/* $out/lib/
            cp ${protocolLib}/lib/liblogos_protocol.${libExt} $out/lib/
            [ -d "${logosLiblogos}/bin" ] && cp -r ${logosLiblogos}/bin/* $out/bin/
            [ -d "${logosLiblogos}/include" ] && cp -r ${logosLiblogos}/include/* $out/include/
            [ -d "${logosLiblogos}/modules" ] && cp -r ${logosLiblogos}/modules/* $out/modules/

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Logos Nim SDK — lp_* consumer plus an embeddable core";
            platforms = platforms.unix;
            maintainers = [ ];
          };
        };
      });

      checks = forAllSystems ({ pkgs, logosLiblogos, protocolLib, basicModule
                              , libExt, ... }:
        let
          protocolLibPath = "${protocolLib}/lib/liblogos_protocol.${libExt}";

          # One derivation shape for both checks: compile a Nim test binary
          # against the SDK sources, then run it. A failing `unittest` suite
          # exits non-zero, which fails the derivation.
          mkNimCheck = { name, entry, env ? "" }:
            pkgs.stdenv.mkDerivation {
              pname = "logos-nim-sdk-${name}";
              version = "2.0.0";
              src = ./.;
              nativeBuildInputs = [ pkgs.nim ];
              buildPhase = ''
                runHook preBuild
                export HOME=$TMPDIR
                nim c --hints:off --nimcache:$TMPDIR/nimcache \
                      -o:$TMPDIR/runner ${entry}
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                export HOME=$TMPDIR
                export LOGOS_PROTOCOL_LIB=${protocolLibPath}
                ${env}
                $TMPDIR/runner
                mkdir -p $out
                touch $out/${name}-passed
                runHook postInstall
              '';
            };
        in
        {
          # Hermetic: needs only the shared protocol library. Pins symbol
          # binding, the JSON-in-strings data model, the canonical error
          # object, string ownership, and the deferred-subscription contract.
          protocol-abi = mkNimCheck {
            name = "protocol-abi";
            entry = "tests/test_protocol_abi.nim";
          };

          # End to end: embedded core, a real module in its own logos_host
          # process, every consumer call over lp_*. No Qt event loop — both
          # modules are put on a plain tcp transport before they load.
          embedded-e2e = mkNimCheck {
            name = "embedded-e2e";
            entry = "tests/test_embedded_e2e.nim";
            env = ''
              export LOGOS_CORE_LIB=${logosLiblogos}/lib/liblogos_core.${libExt}
              export LOGOS_HOST_PATH=${logosLiblogos}/bin/logos_host
              export LOGOS_MODULES_DIR=${basicModule}/modules:${logosLiblogos}/modules
            '';
          };
        }
      );

      devShells = forAllSystems ({ pkgs, logosLiblogos, protocolLib, basicModule
                                 , libExt, ... }: {
        default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.nim pkgs.nimlangserver ];

          shellHook = ''
            export LOGOS_PROTOCOL_LIB="${protocolLib}/lib/liblogos_protocol.${libExt}"
            export LOGOS_CORE_LIB="${logosLiblogos}/lib/liblogos_core.${libExt}"
            export LOGOS_HOST_PATH="${logosLiblogos}/bin/logos_host"
            export LOGOS_MODULES_DIR="${basicModule}/modules:${logosLiblogos}/modules"
            echo "🔧 Logos Nim SDK dev shell — nim $(nim --version | head -n1 | cut -d' ' -f4)"
            echo "  LOGOS_PROTOCOL_LIB=$LOGOS_PROTOCOL_LIB"
            echo "  LOGOS_CORE_LIB=$LOGOS_CORE_LIB"
            echo ""
            echo "  nim c -r tests/test_protocol_abi.nim   # hermetic"
            echo "  nim c -r tests/test_embedded_e2e.nim   # end to end"
          '';
        };
      });
    };
}
