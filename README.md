# flclash-nix

把 [FlClash](https://github.com/chen08209/FlClash) 搬进 flake（上游 nixpkgs 已经把
`flclash` 从 unstable 移除了，理由是 "low number of users and lack of maintenance"），
并补上一个在 NixOS 上真的能用的 TUN 开关。

## 用法

```nix
inputs.flclash-nix.url = "github:yefada/flclash-nix";
```

```nix
{ inputs, ... }:
{
  imports = [ inputs.flclash-nix.nixosModules.flclash ];

  programs.flclash = {
    enable = true;
    tunMode = true;
    # owner = "you";   # 系统里只有一个 isNormalUser 账号时会自动取，不用写
  };
}
```

`owner` 之所以需要，是因为 FlClash 的 helper 会校验内核 socket 的属主：
