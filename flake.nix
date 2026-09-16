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
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = {
          xdoor2 = pkgs.python314Packages.callPackage ./nixos/package.nix { };
          image = xdoor2System.config.system.build.sdImage;
          default = self.packages.${system}.xdoor2;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nixos-rebuild
            nixd
            nixfmt
            openssh
            python314
            ruff
            sops
            ty
            uv
            zstd
          ];

          shellHook = ''
            export LANG=C.UTF-8
          '';
        };

        formatter = pkgs.nixfmt;
      }
    ))
    // {
      nixosConfigurations.xdoor2 = xdoor2System;
    };
}
