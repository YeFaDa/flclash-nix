# flclash-nix

A Nix flake that packages [FlClash](https://github.com/chen08209/FlClash) and provides a NixOS module for its TUN mode.

*English | [简体中文](README.zh-CN.md)*

FlClash was removed from nixpkgs for lack of maintenance. This repository maintains the package and adapts the helper-service privilege model introduced upstream in 0.8.93 to NixOS.

## Features

- Built from the upstream stable source; the Go core, the Rust helper and `librust_api.so` are compiled at build time.
- NixOS module: declares the privileged helper service; no setuid wrappers and no manual installation.
- `x86_64-linux` is verified; `aarch64-linux` uses the same build pipeline.

## Installation

### NixOS (flake)

```nix
{
  inputs.flclash-nix.url = "github:YeFaDa/flclash-nix";

  outputs = { nixpkgs, flclash-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        flclash-nix.nixosModules.default
        {
          programs.flclash = {
            enable = true;
            tunMode = true;
            # owner = "username"; # inferred when exactly one normal user exists
          };
        }
      ];
    };
  };
}
```

Apply the configuration with `sudo nixos-rebuild switch`.

### Without installing

```bash
nix run github:YeFaDa/flclash-nix
```

### Package or overlay

```nix
# Overlay: provides pkgs.flclash
nixpkgs.overlays = [ inputs.flclash-nix.overlays.default ];

# Or reference the package directly
programs.flclash.package = inputs.flclash-nix.packages.${pkgs.system}.default;
```

## Module options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.flclash.enable` | bool | `false` | Enable FlClash. |
| `programs.flclash.package` | package | `pkgs.flclash` | Package to use. |
| `programs.flclash.tunMode` | bool | `false` | Enable TUN and the privileged helper service. |
| `programs.flclash.trustedInterface` | bool | `true` | Add the TUN interface to `networking.firewall.trustedInterfaces`; effective only with `tunMode`. |
| `programs.flclash.owner` | null or string | inferred | User running the graphical interface. |

`owner` must match the user running FlClash: the helper verifies the owner of the core socket and refuses to start the core otherwise. It is inferred when the system has exactly one user with `isNormalUser = true`; set it explicitly otherwise.

## TUN mode

- `flclash-helper.service` runs as root and listens on `/run/flclash/helper.sock`. It starts `FlClashCore` on request; the core does not start at boot.
- The helper is required because the GUI runs unprivileged and cannot start a root service on demand.
- The default firewall rules do not block TUN traffic. With strict custom input rules, `trustedInterface` adds the `FlClash` interface to `networking.firewall.trustedInterfaces`.
- `networking.firewall.checkReversePath` must not be `true` or `"strict"`; the module asserts this.

## Maintenance

```bash
./pkgs/flclash/update.sh          # bump version and source hash (requires nix-update)
nix build .#flclash --cores 8
```

`vendorHash` and `cargoHash` must be recomputed when the corresponding dependency sets change; see the comments in `package.nix`.

## Repository layout

```
flake.nix                 # packages / overlays / nixosModules
modules/flclash.nix       # programs.flclash module
pkgs/flclash/package.nix  # packaging: core, helper and rust_api derivations
pkgs/flclash/update.sh    # version update script
```

## Links

- Upstream project: <https://github.com/chen08209/FlClash>
- Issue tracker: <https://github.com/YeFaDa/flclash-nix/issues>
