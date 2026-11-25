# flclash-nix

[FlClash](https://github.com/chen08209/FlClash) 的 Nix flake 打包，附一个在 NixOS 上开箱可用的 TUN 模式模块。

*A Nix flake for FlClash with a working TUN mode on NixOS.*

上游 nixpkgs 已移除 `flclash`（removal reason: lack of maintenance），这个仓库把它重新打出来，并把 0.8.93 之后“root helper 服务”的提权模型适配进了 NixOS 模块。

## 特性

- 跟随上游稳定版源码构建，Go 内核、Rust helper、`librust_api.so` 都在构建期预编译好
- `programs.flclash` 模块：声明 helper 的 systemd 服务，TUN 不用 setuid、不用手动装服务
- 面向 Linux：`x86_64-linux` 已实测，`aarch64-linux` 走同一套构建流程

## 安装

### NixOS（flake）

```nix
{
  inputs.flclash-nix.url = "github:YeFaDa/flclash-nix";

  outputs = { self, nixpkgs, flclash-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        flclash-nix.nixosModules.default
        {
          programs.flclash = {
            enable = true;
            tunMode = true;
            # owner = "your-user";  # 系统里只有一个 isNormalUser 时会自动推断
          };
        }
      ];
    };
  };
}
```

改完 `sudo nixos-rebuild switch` 即可。

### 直接运行（不装进系统）

```bash
nix run github:YeFaDa/flclash-nix
```

### 只用包 / overlay

```nix
# 方式一：overlay，装完就能 pkgs.flclash
nixpkgs.overlays = [ inputs.flclash-nix.overlays.default ];

# 方式二：直接引用
programs.flclash.package = inputs.flclash-nix.packages.${pkgs.system}.default;
```

## 模块选项

| 选项 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `programs.flclash.enable` | bool | `false` | 启用 FlClash |
| `programs.flclash.package` | package | `pkgs.flclash` | 使用的包 |
| `programs.flclash.tunMode` | bool | `false` | 启用 TUN，同时启动 root 的 helper 服务 |
| `programs.flclash.trustedInterface` | bool | `true` | 把 TUN 网卡加进 `networking.firewall.trustedInterfaces`，仅在 `tunMode` 下生效 |
| `programs.flclash.owner` | null / str | 自动推断 | 运行图形界面的用户 |

`owner` 不是可选的美化项：FlClash 的 helper 会校验内核 socket 的属主必须等于这个用户，
不匹配就拒绝启动内核。系统里恰好只有一个 `isNormalUser = true` 的账号时会自动取它，
否则必须显式指定。

## TUN 模式说明

- 模块提供 `flclash-helper.service`，以 root 常驻并监听 `/run/flclash/helper.sock`。
  它只负责在 GUI 请求时启动内核，**内核本身不会开机自启**：打开 FlClash 才有
  `FlClashCore` 进程，退出即停。
- 之所以要常驻：GUI 是普通用户，没有权限临时拉起一个 root 服务，只能请求已经运行的 helper。
- 默认防火墙规则不会拦 TUN（回包都命中 `ESTABLISHED`，`checkReversePath` 默认 `loose`）。
  如果自定义了严格的 input 规则，`trustedInterface` 会把 `FlClash` 网卡加进
  `networking.firewall.trustedInterfaces`；也可以在 FlClash 设置里改过网卡名后关掉它自行添加。
- 模块会断言 `networking.firewall.checkReversePath` 不是 `true`/`"strict"`，
  否则反向路径过滤会丢掉 TUN 回包。

## 维护

```bash
# 上游发版后
./pkgs/flclash/update.sh     # 需要 nix-update，会更新版本号与 src 哈希
nix build .#flclash --cores 8
```

`package.nix` 里 Go / Rust 的 `vendorHash`、`cargoHash` 在依赖变化时需要重算，
编译时的具体做法见文件内注释。

## 目录结构

```
flake.nix                 # packages / overlays / nixosModules
modules/flclash.nix       # programs.flclash 模块
pkgs/flclash/package.nix  # 打包：core、helper、rust_api 三个 derivation
pkgs/flclash/update.sh    # 版本升级脚本
```

## 相关链接

- 上游项目：<https://github.com/chen08209/FlClash>
- 问题反馈：<https://github.com/YeFaDa/flclash-nix/issues>
