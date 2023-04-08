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
            (writeShellScriptBin "ssh" ''
              if [ ! -f id_rsa ]; then
                ${openssh}/bin/ssh-keygen -t rsa -N "" -f id_rsa > /dev/null
              fi

              ${openssh}/bin/ssh -i id_rsa.pub -o StrictHostKeyChecking=no "$@"
            '')
          ];

          runScript = "${zig}/bin/zig";
        };

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

        configurePhase = ''
          ${concatStrings (attrValues (mapAttrs (path: src: ''
            echo "Linking ${src} -> $NIX_BUILD_TOP/source/src/${path}"
            rm -rf $NIX_BUILD_TOP/source/src/${path}
            cp -r -P --no-preserve=ownership,mode ${src} $NIX_BUILD_TOP/source/src/${path}
          '') sources))}
        '';

        mkPkg = target:
          let
            src = cleanSource self;
            buildFlags = optional (target != null) "-Dtarget=${target}";

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

            FLUTTER_SOURCE = pkgs.stdenv.mkDerivation {
              pname = "zig-flutter-source${optionalString (target != null) "-${target}"}";
              inherit version configurePhase passthru src buildFlags gclient;

              dontBuild = true;

              NIX_SSL_CERT_FILE = "${pkgs.buildPackages.cacert}/etc/ssl/certs/ca-bundle.crt";
              SSL_CERT_FILE = "${pkgs.buildPackages.cacert}/etc/ssl/certs/ca-bundle.crt";

              installPhase = ''
                export XDG_CACHE_HOME=$NIX_BUILD_TOP/.cache
                ${fhsEnv}/bin/${fhsEnv.name} build source --prefix $out -Dgclient=$gclient $buildFlags
              '';

              dontFixup = true;

              outputHashAlgo = "sha256";
              outputHash = fakeHash;
            };
          in pkgs.stdenv.mkDerivation {
            pname = "zig-flutter${optionalString (target != null) "-${target}"}";
            inherit version configurePhase src FLUTTER_SOURCE gclient buildFlags;

            dontBuild = true;

            installPhase = ''
              export XDG_CACHE_HOME=$NIX_BUILD_TOP/.cache
              ${fhsEnv}/bin/${fhsEnv.name} build --prefix $out -Dgclient=$gclient -Dsource=$FLUTTER_SOURCE $buildFlags
            '';
          };

          packages = {
            default = mkPkg null;
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
