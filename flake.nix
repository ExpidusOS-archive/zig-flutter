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
        
        version = "git+${self.shortRev or "dirty"}";
        fhsEnv = pkgs.buildFHSUserEnv {
          name = "zig-flutter-${version}";

          targetPkgs = pkgs: with pkgs.buildPackages; [
            zigpkgs.master
            (python3.withPackages (p: [ p.httplib2 p.six ]))
            pkg-config
            ninja
            zlib
          ];
        };

        # Keep up to date with submodules
        sources = {
          "depot_tools" = pkgs.fetchGit {
            name = "depot_tools";
            url = "https://chromium.googlesource.com/chromium/tools/depot_tools.git";
            rev = "61ebd177abdc56bd373fc05c0101e2e506f9d758";
          };
          "flutter" = pkgs.fetchFromGitHub {
            owner = "flutter";
            repo = "engine";
            rev = "ec975089acb540fc60752606a3d3ba809dd1528b";
          };
        };

        mkPkg = target:
          pkgs.stdenv.mkDerivation {
            pname = "zig-flutter${optionalString (target != null) "-${target}"}";
            inherit version;

            src = cleanSource self;

            configurePhase = ''
              ${concatStrings (attrValues (mapAttrs (path: src: ''
                echo "Linking ${src} -> $NIX_BUILD_TOP/source/src/${path}"
                rm -rf $NIX_BUILD_TOP/source/src/${path}
                cp -r -P --no-preserve=ownership,mode ${src} $NIX_BUILD_TOP/source/src/${path}
              '') sources ))}
            '';

            buildFlags = optional (target != null) "-Dtarget=${target}";

            installPhase = ''
              ${fhsEnv}/bin/${fhsEnv.name} ${pkgs.buildPackages.zigpkgs.master} build --prefix $out $buildFlags
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

              function installPhase {
                export NIX_BUILD_TOP=$HOME
                rm -rf $rootOut
                ${pkg.installPhase}
              }
            '';
          }) packages;
      });
}
