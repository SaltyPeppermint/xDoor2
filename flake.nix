{
  description = "xdoor but python";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      xdoor2System = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs.xdoor2Package = self.packages.aarch64-linux.xdoor2;
        modules = [ ./nixos/rpi3-image.nix ];
      };
    in
    (flake-utils.lib.eachSystem [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;

        mkApp = name: description: runtimeInputs: text: {
          type = "app";
          meta.description = description;
          program = lib.getExe (pkgs.writeShellApplication { inherit name runtimeInputs text; });
        };

        # HOST and SSH_PORT can be set as ENV vars
        target = ''
          HOST="''${HOST:-xdoor2.lan.xhain.space}"
          SSH_PORT="''${SSH_PORT:-23}"
          SSH_DEST="admin@$HOST"
        '';
      in
      {
        packages = {
          image = xdoor2System.config.system.build.sdImage;
        }
        # The package only builds for Linux cause of gpiozero
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          xdoor2 = pkgs.python314Packages.callPackage ./nixos/package.nix { };
          default = self.packages.${system}.xdoor2;
        };

        apps = {
          deploy =
            mkApp "xdoor2-deploy" "Switch a booted device to this NixOS configuration"
              [ pkgs.nixos-rebuild pkgs.openssh ]
              ''
                ${target}
                NIX_SSHOPTS="-p $SSH_PORT" exec nixos-rebuild switch \
                  --flake ${self}#xdoor2 \
                  --target-host "$SSH_DEST" \
                  --elevate sudo \
                  "$@"
              '';

          shell = mkApp "xdoor2-shell" "Open the administrative SSH console" [ pkgs.openssh ] ''
            ${target}
            exec ssh -p "$SSH_PORT" "$SSH_DEST" "$@"
          '';

          flash = mkApp "xdoor2-flash" "Write the SD image to a card" [ ] ''
            DEVICE="''${1:?usage: nix run .#flash -- /dev/your-sd-card}"
            IMAGE=(${self.packages.aarch64-linux.image}/sd-image/*.img)
            # MacOS thinks its special about writing to mounted disks and you have to do a little dance
            if [ "$(uname -s)" = Darwin ]; then
              diskutil unmountDisk "$DEVICE"
              DEVICE="/dev/r''${DEVICE#/dev/}"
            fi
            sudo dd if="''${IMAGE[0]}" of="$DEVICE" bs=4194304 status=progress
            sync
          '';

          lint =
            mkApp "xdoor2-lint" "Run ruff and ty"
              [
                pkgs.ruff
                pkgs.ty
                pkgs.uv
                pkgs.python314
              ]
              ''
                uv sync --frozen --quiet
                ruff check .
                ty check src
              '';
        };

        checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          xdoor2 = self.packages.${system}.xdoor2;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nixos-rebuild
            nixd
            nixfmt
            openssh
            python314
            ruff
            ty
            uv
          ];

          shellHook = ''
            export LANG=C.UTF-8
            # No real GPIO on a dev machine so we use gpiozero's MockFactory
            export GPIOZERO_PIN_FACTORY=mock
          '';
        };

        formatter = pkgs.writeShellApplication {
          name = "xdoor2-fmt";
          runtimeInputs = [
            pkgs.ruff
            pkgs.nixfmt
            pkgs.fd
          ];
          text = ''
            ruff format .
            ruff check --fix .
            fd -e nix -X nixfmt
          '';
        };
      }
    ))
    // {
      nixosConfigurations.xdoor2 = xdoor2System;
    };
}
