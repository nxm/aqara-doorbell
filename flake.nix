{
  description = "Unofficial Aqara G410 doorbell: a macOS live-view/talkback client and a Matrix motion notifier, built on a reverse-engineered protocol.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # NixOS module for the notifier daemon (Linux). Consume from your own
      # flake: imports = [ inputs.aqara-doorbell.nixosModules.default ];
      nixosModule = import ./notifier/module.nix { inherit self; };
    in
    {
      nixosModules.default = nixosModule;
      nixosModules.aqara-doorbell = nixosModule;
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pythonEnv = pkgs.python3.withPackages (ps: [ ps.cryptography ]);
        notifier = pkgs.writeShellApplication {
          name = "aqara-doorbell-notify";
          runtimeInputs = [ pythonEnv ];
          text = ''exec python3 ${./notifier/aqara_doorbell_notify.py} "$@"'';
        };
      in
      {
        packages = {
          notifier = notifier;
          default = notifier;
        }
        # The menu-bar app (prebuilt release bundle). For nix-darwin, add it to
        # environment.systemPackages or any option that links $out/Applications.
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
          macos = pkgs.callPackage ./macos/package.nix { };
        };

        apps.notifier = {
          type = "app";
          program = "${notifier}/bin/aqara-doorbell-notify";
        };
        apps.default = self.apps.${system}.notifier;

        # `nix develop` then `./macos/make-app.sh` to build the .app bundle,
        # or run the notifier directly with the env vars from its README.
        devShells.default = pkgs.mkShell {
          packages = [ pythonEnv ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.swift ];
        };
      });
}
