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

        # Boots nixpkgs' darwin.linux-builder-vz VM only for the duration of the given command
        linuxBuilder = pkgs.writeShellApplication {
          name = "xdoor2-linux-builder";
          runtimeInputs = [ pkgs.openssh ];
          text =
            let
              builder = pkgs.darwin.linux-builder-vz;
            in
            ''
              DIR="''${LINUX_BUILDER_DIR:-$HOME/.linux-builder}"
              mkdir -p "$DIR"

              # Installs the SSH key into /etc/nix, only asks for sudo on first run
              (cd "$DIR" && ${lib.getExe builder.passthru.add-keys}) >&2

              # Own process group so the whole VM tree can be killed at once
              set -m
              (cd "$DIR" && exec ${lib.getExe builder.passthru.run-builder}) </dev/null >"$DIR/vm.log" 2>&1 &
              VM_PID=$!
              set +m
              trap 'kill -- -"$VM_PID" 2>/dev/null || true' EXIT

              # The guest console goes to the macOS unified log, not to vm.log
              LOG_HINT="/usr/bin/log show --last 5m --predicate 'subsystem == \"systems.applicative.vzvm\"'"
              echo "Waiting for the linux-builder VM (logs: $DIR/vm.log and $LOG_HINT)" >&2
              until ssh-keyscan -p 31022 127.0.0.1 >/dev/null 2>&1; do
                kill -0 "$VM_PID" 2>/dev/null || { echo "linux-builder VM exited, see $DIR/vm.log and $LOG_HINT" >&2; exit 1; }
                sleep 1
              done

              "$@"
            '';
        };

        # On macOS the linux-builder VM only gets started when something actually needs building.
        ensureBuilt = lib.getExe (
          pkgs.writeShellApplication {
            name = "xdoor2-ensure-built";
            text = ''
              ATTR="${self}#''${1:?usage: xdoor2-ensure-built <flake attribute>}"
              OUT="$(nix eval --raw "$ATTR.outPath")"
              if ! nix path-info "$OUT" >/dev/null 2>&1; then
                ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin (lib.getExe linuxBuilder)} nix build --no-link "$ATTR" >&2
              fi
              echo "$OUT"
            '';
          }
        );

        # Runtime deps plus test tools for development, the single source of Python packages
        devPython = pkgs.python314.withPackages (
          ps:
          let
            # nixpkgs marks gpiozero Linux-only, but it's pure Python and we only use MockFactory locally
            gpiozero = ps.gpiozero.overridePythonAttrs (old: {
              meta = old.meta // {
                platforms = lib.platforms.all;
              };
              doCheck = false;
            });
          in
          [
            ps.asyncssh
            ps.cryptography
            gpiozero
            ps.httpx
            ps.paho-mqtt
            ps.pytest
            ps.pytest-asyncio
          ]
        );

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
                ${ensureBuilt} nixosConfigurations.xdoor2.config.system.build.toplevel >/dev/null
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

          image = mkApp "xdoor2-image" "Build the SD image into ./result" [ ] ''
            ${ensureBuilt} packages.aarch64-linux.image >/dev/null
            nix build ${self}#packages.aarch64-linux.image "$@"
          '';

          flash = mkApp "xdoor2-flash" "Write the SD image to a card" [ ] ''
            DEVICE="''${1:?usage: nix run .#flash -- /dev/your-sd-card}"
            IMAGE_DIR="$(${ensureBuilt} packages.aarch64-linux.image)"
            IMAGE=("$IMAGE_DIR"/sd-image/*.img)
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
              ]
              ''
                ruff check .
                ty check --python ${devPython}/bin/python src
              '';
        };

        checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          xdoor2 = self.packages.${system}.xdoor2;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            devPython
            nixos-rebuild
            nixd
            nixfmt
            openssh
            ruff
            ty
          ];

          shellHook = ''
            export LANG=C.UTF-8
            export PYTHONPATH="$PWD/src''${PYTHONPATH:+:$PYTHONPATH}"
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
