{
  description = "A Lua script for tagging and organizing files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
  };

  outputs = {
    self,
    nixpkgs,
    systems,
  }: let
    inherit (nixpkgs) lib;
    eachSystem = lib.genAttrs (import systems);
    pkgsFor = eachSystem (system:
      import nixpkgs {
        config = {};
        localSystem = system;
        overlays = [];
      });
  in {
    packages = eachSystem (system: {
      clutag = pkgsFor.${system}.callPackage ./default.nix {};
      default = self.packages.${system}.clutag;
    });
  };
}

