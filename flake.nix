{
  description = "FlClash for NixOS — 带可用的 TUN（虚拟网卡）模式";

  inputs = {
    # 包依赖 flutter335，nixos-unstable 上有这个属性集（已验证）。
    # 想锁到别的分支就改这里，或者用 inputs.flclash-tun.nixpkgs.follows 复用你自己的 nixpkgs。
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    {
      overlays.default = final: prev: {
        flclash = final.callPackage ./pkgs/flclash/package.nix { };
      };

      nixosModules.default = self.nixosModules.flclash;

      # 自动挂上 overlay，这样 programs.flclash.package 默认就是本仓库的 flclash
      nixosModules.flclash = {
        imports = [ ./modules/flclash.nix ];
        nixpkgs.overlays = [ self.overlays.default ];
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
      in
      {
        packages = {
          flclash = pkgs.flclash;
          flclashCore = pkgs.flclash.core;
          flclashHelper = pkgs.flclash.helper;
          flclashRustApi = pkgs.flclash.rustApi;
          default = pkgs.flclash;
        };
      }
    );
}
