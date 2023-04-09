{
  description = "Flutter w/ Zig";

  nixConfig = rec {
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=" ];
    substituters = [ "https://cache.nixos.org" "https://cache.garnix.io" ];
    trusted-substituters = substituters;
    fallback = true;
    http2 = false;
  };

  inputs.expidus-sdk.url = github:ExpidusOS/sdk/feat/refactor-neutron;

  outputs = { self, expidus-sdk }:
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
            (writeShellScriptBin "ssh" ''
              if [ ! -f id_rsa ]; then
                ${openssh}/bin/ssh-keygen -t rsa -N "" -f id_rsa > /dev/null
              fi

              ${openssh}/bin/ssh -i id_rsa.pub -o StrictHostKeyChecking=no "$@"
            '')
          ];

          runScript = "${zig}/bin/zig";
        };

        VPYTHON_BYPASS = "manually managed python not supported by chrome operations";

        # Keep up to date with submodules
        sources = {
          "depot_tools" = pkgs.fetchgit {
            name = "depot_tools";
            url = "https://chromium.googlesource.com/chromium/tools/depot_tools.git";
            rev = "61ebd177abdc56bd373fc05c0101e2e506f9d758";
            sha256 = "sha256-JHzNj5lR93s8gZC68YX+WZgJy6k5ioYGq4MeCwWvXtA=";
          };
          "flutter" = pkgs.fetchFromGitHub {
            owner = "flutter";
            repo = "engine";
            rev = "ec975089acb540fc60752606a3d3ba809dd1528b";
            sha256 = "sha256-pin+VZbO54RxmTxBpdK+1xatGZq20phLeSSCl+WKHUI=";
          };
        };

        depot_toolsFhsEnv = pkgs.buildFHSUserEnv {
          name = "depot_tools";

          targetPkgs = pkgs: with pkgs.buildPackages; [
            (python3.withPackages (p: [ p.httplib2 p.six ]))
            git
            curl
          ];
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

        mkPkg = { target ? null, engineHash ? fakeHash, buildFlags ? [] }@args:
          let
            src = cleanSource self;
            buildFlags = (args.buildFlags or []) ++ optional (target != null) "-Dtarget=${target}";

            passthru = {
              inherit sources;
            };

            gclient = pkgs.stdenv.mkDerivation {
              pname = "zig-flutter${optionalString (target != null) "-${target}"}.gclient";
              inherit version configurePhase passthru src buildFlags;

              dontBuild = true;

              installPhase = ''
                export XDG_CACHE_HOME=$NIX_BUILD_TOP/.cache
                ${fhsEnv}/bin/${fhsEnv.name} build gclient --prefix $NIX_BUILD_TOP/install $buildFlags
                mv $NIX_BUILD_TOP/install/.gclient $out
                sed -i "s|file://$NIX_BUILD_TOP/source/src/flutter|${sources.flutter.gitRepoUrl}@${sources.flutter.rev}|g" $out
              '';
            };

            FLUTTER_ENGINE = pkgs.stdenv.mkDerivation {
              pname = "zig-flutter-source${optionalString (target != null) "-${target}"}";
              inherit version configurePhase passthru src buildFlags gclient;

              dontBuild = true;

              NIX_SSL_CERT_FILE = "${pkgs.buildPackages.cacert}/etc/ssl/certs/ca-bundle.crt";
              SSL_CERT_FILE = "${pkgs.buildPackages.cacert}/etc/ssl/certs/ca-bundle.crt";

              installPhase = ''
                export XDG_CACHE_HOME=$NIX_BUILD_TOP/.cache
                ${fhsEnv}/bin/${fhsEnv.name} build source --prefix $out -Dgclient=$gclient $buildFlags

                find $out -name '*.pyc' -type f -delete
                find $out -name 'package_config.json' -type f -exec sed -i '/"generated": /d' {} \;
                find $out -name '.git' -type d -exec ${pkgs.writeShellScript "fake-git" ''
                  src=$1
                  rm -rf $src
                  mkdir -p $src/logs
                  echo "${fakeHash}" >$src/logs/HEAD
                ''} {} \;

                cp ${pkgs.writeText "fake-git.py" ''
                  #!${pkgs.python3}/bin/python3

                  print("${fakeHash}")
                ''} $out/src/flutter/build/git_revision.py
              '';

              dontFixup = true;

              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = engineHash;
            };
          in pkgs.stdenv.mkDerivation {
            pname = "zig-flutter${optionalString (target != null) "-${target}"}";
            inherit version configurePhase src gclient buildFlags VPYTHON_BYPASS;

            dontBuild = true;

            buildInputs = [
              FLUTTER_ENGINE
            ];

            installPhase = ''
              export XDG_CACHE_HOME=$NIX_BUILD_TOP/.cache
              ls ${FLUTTER_ENGINE}
              ${fhsEnv}/bin/${fhsEnv.name} build --prefix $out -Dgclient=$gclient -Dsource=${FLUTTER_ENGINE} $buildFlags
            '';
          };

          packages = {
            default = mkPkg {
              target = null;
              engineHash = "sha256-lAI8AqreeOR/xpPNUGOlvPDYjJ5GDSOSU4xj/eJ7ykE=";
            };
          } // mapAttrs (target: cfg: mkPkg (cfg // {
            inherit target;
          })) {
            "wasm32-freestanding-musl" = {
              engineHash = "sha256-4ouL8IpxOqUMY2kkgp3f/tBFxhC9qklTWUCNSCepiBE=";
              buildFlags = [];
            };
            "x86_64-linux-gnu" = {
              engineHash = "sha256-lAI8AqreeOR/xpPNUGOlvPDYjJ5GDSOSU4xj/eJ7ykE=";
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
