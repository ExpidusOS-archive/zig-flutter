{
  description = "Flutter w/ Zig";

  nixConfig = rec {
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=" ];
    substituters = [ "https://cache.nixos.org" "https://cache.garnix.io" ];
    trusted-substituters = substituters;
    fallback = true;
    http2 = false;
  };

  inputs.expidus-sdk = {
    url = github:ExpidusOS/sdk/feat/refactor-neutron;
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.nixpkgs.url = github:ExpidusOS/nixpkgs;

  outputs = { self, expidus-sdk, ... }:
    with expidus-sdk.lib;
    flake-utils.eachSystem flake-utils.allSystems (system:
      let
        pkgs = expidus-sdk.legacyPackages.${system};

        zig = pkgs.buildPackages.zigpkgs.master;
        
        version = "git+${self.shortRev or "dirty"}";
        fhsEnv = pkgs.buildFHSUserEnv {
          name = "zig-flutter-${version}";

          targetPkgs = pkgs: with pkgs.buildPackages; [
            zig
            (python3.withPackages (p: [ p.httplib2 p.six ]))
            pkg-config
            ninja
            zlib
            git
            curl
          ];

          runScript = "${zig}/bin/zig";
        };

        VPYTHON_BYPASS = "manually managed python not supported by chrome operations";

        FLUTTER_ENGINE = pkgs.flutter-engine.src;

        # Keep up to date with submodules
        sources = {
          "depot_tools" = pkgs.fetchgit {
            name = "depot_tools";
            url = "https://chromium.googlesource.com/chromium/tools/depot_tools.git";
            rev = "61ebd177abdc56bd373fc05c0101e2e506f9d758";
            sha256 = "sha256-JHzNj5lR93s8gZC68YX+WZgJy6k5ioYGq4MeCwWvXtA=";
          };
          "flutter" = "${FLUTTER_ENGINE}/src/flutter";
        };

        configurePhase = ''
          runHook preConfigure

          ${concatStrings (attrValues (mapAttrs (path: src: ''
            echo "Linking ${src} -> $NIX_BUILD_TOP/source/src/${path}"
            rm -rf $NIX_BUILD_TOP/source/src/${path}
            cp -r -P --no-preserve=ownership,mode ${src} $NIX_BUILD_TOP/source/src/${path}
          '') sources))}

          for name in cipd vpython3; do
            chmod +x $NIX_BUILD_TOP/source/src/depot_tools/$name
          done

          runHook postConfigure
        '';

        mkPkg = { target ? null, buildFlags ? [] }@args:
          let
            src = cleanSource self;
            buildFlags = (args.buildFlags or []) ++ optional (target != null) "-Dtarget=${target}";
          in pkgs.stdenv.mkDerivation {
            pname = "zig-flutter${optionalString (target != null) "-${target}"}";
            inherit version configurePhase src buildFlags VPYTHON_BYPASS FLUTTER_ENGINE;
            inherit (FLUTTER_ENGINE) gclient;

            engineExecs = [
              "src/third_party/dart/tools/sdks/dart-sdk/bin/dart"
              "src/third_party/dart/build/gn_run_binary.py"
              "src/flutter/third_party/gn/gn"
            ];

            postUnpack = ''
              cp -r -P --no-preserve=ownership,mode $FLUTTER_ENGINE $NIX_BUILD_TOP/flutter-engine
              for name in ''${engineExecs[@]}; do
                chmod +x $NIX_BUILD_TOP/flutter-engine/$name
              done

              rm -rf $NIX_BUILD_TOP/flutter-engine/src/buildtools
              ln -s $FLUTTER_ENGINE/src/buildtools $NIX_BUILD_TOP/flutter-engine/src/buildtools

              rm -rf $NIX_BUILD_TOP/flutter-engine/src/build/linux
              ln -s $FLUTTER_ENGINE/src/build/linux $NIX_BUILD_TOP/flutter-engine/src/build/linux
            '';

            dontBuild = true;

            installPhase = ''
              export XDG_CACHE_HOME=$NIX_BUILD_TOP/.cache
              ${fhsEnv}/bin/${fhsEnv.name} build --prefix $out -Dgclient=$gclient -Dsource=$NIX_BUILD_TOP/flutter-engine $buildFlags
            '';
          };

          packages = {
            default = mkPkg {
              target = null;
            };
          } // mapAttrs (target: cfg: mkPkg (cfg // {
            inherit target;
          })) {
            "wasm32-freestanding-musl" = {
              buildFlags = [];
            };
            "x86_64-linux-gnu" = {
              buildFlags = [];
            };
          };
      in {
        inherit packages;

        devShells = mapAttrs (name: pkg:
          pkgs.mkShell {
            inherit (pkg) pname name version buildFlags;

            shellHook = ''
              export rootOut=$(dirname $out)
              export devdocs=$rootOut/devdocs
              export src=$(dirname $rootOut)
              alias zig=${fhsEnv}/bin/${fhsEnv.name}

              function installPhase {
                ${fhsEnv}/bin/${fhsEnv.name} build --prefix $out $buildFlags
              }
            '';
          }) packages;
      });
}
