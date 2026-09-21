# FlClash 的 NixOS 模块
#
# 0.8.93 起上游换了提权模型，不再靠给二进制加 setuid，而是让一个 **root 的
# systemd 服务**（FlClashHelperService）来启动内核。GUI 侧的判断是：
#
#   bool get hasHelperService => isWindows || (isLinux && !isAppImage && _hasSystemd);
#
#   Future<bool> checkIsAdmin() async {
#     if (hasHelperService) return await helperClient.readiness() == HelperReadiness.ready;
#     ...  // 下面那套老的 stat + setuid 才会被走到
#   }
#
# 也就是说在 NixOS 上（有 /run/systemd/system）它**根本不看 setuid**，只问 helper 在不在。
# 所以这里不再需要 security.wrappers，改成提供那个 systemd 服务。
#
# 上游的做法是 GUI 侧用 pkexec 把 unit 写到 /etc/systemd/system/flclash-helper.service，
# 但 NixOS 上那个目录是只读的，自安装必然失败 —— 这正是模块要替它做的事。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.flclash;

  # 只有一个普通用户时就没有歧义，可以自动推断 owner。
  # 有两个以上（或一个都没有）时仍然要求显式指定 —— 见下面的断言。
  normalUsers = lib.attrNames (
    lib.filterAttrs (_: user: user.isNormalUser or false) config.users.users
  );
  detectedOwner = if lib.length normalUsers == 1 then lib.head normalUsers else null;

  # owner 为 null 时别让 escapeShellArg 先抛 "expected a string" 把断言的可读信息盖掉
  ownerName = if cfg.owner == null then "root" else cfg.owner;

  # helper 只对自己的 unix socket 做 chmod 0660，**不 chown**
  # （services/helper/src/service/linux.rs），所以 socket 的属组就是服务进程的 gid。
  # 上游 unit 里对应的是 `Group={调用者的主组 gid}` —— 不给的话 socket 变成 root:root，
  # GUI 连不上，readiness() 失败，HelperLauncherResolver 就退回 directLauncher
  # 以普通用户启动内核，TUN 自然建不起来。
  # NixOS 里没法在 eval 期把用户名换算成 gid，只能拿组名；
  # users.users.<name>.group 没设时，普通用户的主组是 users(100)。
  ownerGroup =
    let
      configured = if cfg.owner == null then "" else config.users.users.${cfg.owner}.group;
    in
    if configured != "" then configured else "users";

  # 兜底：服务起来后按用户**真实**主组再 chgrp 一次（id -gn 是运行期求值，一定准）。
  # 上面推导对了这就是空操作。
  fixSocketGroup = pkgs.writeShellScript "flclash-helper-chgrp" ''
    for _ in $(seq 1 50); do
      if [ -S /run/flclash/helper.sock ]; then
        ${pkgs.coreutils}/bin/chgrp "$(${pkgs.coreutils}/bin/id -gn ${lib.escapeShellArg ownerName})" \
          /run/flclash/helper.sock
        exit 0
      fi
      sleep 0.1
    done
    exit 0
  '';

  # 上游 unit 里 uid/gid 是运行时给 helper 用的，见下面的启动脚本
  startScript = pkgs.writeShellScript "flclash-helper-start" ''
    # helper 要求 OWNER_UID/OWNER_GID 都是**非 0** 的 ID（parse_owner_id 会拒绝 0），
    # 并且会拿它们去校验内核 socket 的属主、以及 chown 自己的 unix socket。
    # 这里在运行期用 id 解析：NixOS 里 users.users.<name>.uid 可能是 null（激活时才分配）。
    export FLCLASH_HELPER_OWNER_UID="$(id -u ${lib.escapeShellArg ownerName})"
    export FLCLASH_HELPER_OWNER_GID="$(id -g ${lib.escapeShellArg ownerName})"
    exec ${cfg.package}/bin/FlClashHelperService
  '';
in
{
  options.programs.flclash = {
    enable = lib.mkEnableOption "FlClash，一个基于 ClashMeta 的代理客户端";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.flclash;
      defaultText = lib.literalExpression "pkgs.flclash";
      description = "使用的 FlClash 包。";
    };

    tunMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        是否启用 TUN（虚拟网卡）模式。

        打开后会以 root 身份运行 {command}`FlClashHelperService` systemd 服务，
        FlClash 的内核改由这个服务启动，因此能创建 TUN 接口。

        同时会把 {option}`networking.firewall.checkReversePath` 设为 `loose`，
        否则反向路径过滤会把 TUN 回来的流量丢掉。
      '';
    };

    trustedInterface = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        把 FlClash 的 TUN 接口加入 {option}`networking.firewall.trustedInterfaces`。

        FlClash 的 TUN 网卡名默认取 {var}`appName`，即 `FlClash`
        （lib/models/generated/clash_config.g.dart: `device ?? appName`）。
        仅在 `tunMode = true` 时生效。

        NixOS 防火墙默认规则其实不拦 TUN 回包（ESTABLISHED 放行 +
        checkReversePath 默认 loose），这个选项是给自定义了严格 input
        规则的用户兜底的。注意：如果你在 FlClash 设置里改过 TUN 网卡名，
        这里就不会匹配，请关掉本选项并自行把新名字加进
        {option}`networking.firewall.trustedInterfaces`。
      '';
    };

    owner = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = detectedOwner;
      defaultText = lib.literalExpression "系统里唯一的 isNormalUser 用户，没有或有多个时为 null";
      example = "alice";
      description = ''
        运行 FlClash 图形界面的用户名。

        FlClash 的 helper 会校验内核 socket（由 GUI 创建）的属主必须等于这个用户，
        否则拒绝启动内核，所以必须跟实际登录的账号一致。

        系统里只有一个 {option}`users.users.<name>.isNormalUser` 为 `true` 的账号时
        会自动取它；有多个（或一个都没有）就必须显式指定，
        否则 {option}`programs.flclash.tunMode` 会触发断言。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.services.flclash-helper = lib.mkIf cfg.tunMode {
      description = "FlClash Helper 以 root 启动 FlClash 内核（TUN 模式需要）";

      # 依赖与重启策略照抄上游 unit
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nftables.service"
        "iptables.service"
      ];
      startLimitIntervalSec = 60;
      startLimitBurst = 5;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = toString startScript;
        ExecStartPost = toString fixSocketGroup;

        # 不设 User=，服务以 root 运行，内核才有 CAP_NET_ADMIN
        RuntimeDirectory = "flclash";
        RuntimeDirectoryMode = "0755";

        # 决定 helper.sock 的属组，好让 GUI 用户连得上，见上面 ownerGroup 的注释
        Group = ownerGroup;

        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # 注：NixOS 里 checkReversePath 的默认值本来就是 "loose"，这里写出来只是表态。
    # 真正有用的是下面那条断言 —— 用户显式设成 true/"strict" 时会被拦下。
    networking.firewall.checkReversePath = lib.mkIf cfg.tunMode (lib.mkDefault "loose");

    # types.listOf 的 merge 是拼接语义，用户自己写的 trustedInterfaces 不会被覆盖。
    networking.firewall.trustedInterfaces =
      lib.mkIf (cfg.tunMode && cfg.trustedInterface) [ "FlClash" ];

    assertions = [
      {
        assertion =
          !cfg.tunMode
          || config.networking.firewall.checkReversePath != true
          && config.networking.firewall.checkReversePath != "strict";
        message = ''
          {option}`programs.flclash.tunMode` 需要
          {option}`networking.firewall.checkReversePath` 为 `false` 或 `"loose"`，
          否则反向路径过滤会把 TUN 回来的流量丢掉。
        '';
      }
      {
        assertion = !cfg.tunMode || cfg.owner != null;
        message = ''
          {option}`programs.flclash.tunMode` 需要知道是哪个用户在跑 FlClash，
          但没能自动推断出来。

          FlClash 的 helper 会校验内核 socket 的属主必须等于那个用户，
          而系统里有 ${toString (lib.length normalUsers)} 个
          {option}`users.users.<name>.isNormalUser` = true 的账号（只有恰好 1 个才能自动取）。

          请显式设置 {option}`programs.flclash.owner` = "<运行 FlClash 的用户名>"。
        '';
      }
      {
        assertion = cfg.owner == null || config.users.users ? ${cfg.owner};
        message = "programs.flclash.owner 指定的用户不存在。";
      }
    ];
  };
}
