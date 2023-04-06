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
        
        version = "git+${self.shortRev or "dirt"}";

        targetPkgs = pkgs: with pkgs; [
          zigpkgs.master
          (python3.withPackages (p: [ p.httplib2 p.six ]))
        ];
      in {
        devShells.default = (pkgs.buildFHSUserEnv {
          name = "flutter-nix";

          inherit targetPkgs;

          profile = "bash";
        }).env;
      });
}
