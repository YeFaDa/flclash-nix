{
  lib,
  fetchFromGitHub,
  flutter347,
  keybinder3,
  libayatana-appindicator,
  buildGo127Module,
  rustPlatform,
  makeDesktopItem,
  copyDesktopItems,
  autoPatchelfHook,
  imagemagick,
  libx11,
}:

let
  pname = "flclash";
  version = "0.9.3";

  src = fetchFromGitHub {
    owner = "chen08209";
    repo = "FlClash";
    tag = "v${version}";
    preFetch = ''
      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf
      export GIT_CONFIG_VALUE_0=git@github.com:
    '';
    hash = "sha256-HVyVBCmFzSAdp2NtPS8vIwqo67d/e0klgAHd/MbJzEg=";
    fetchSubmodules = true;
  };

  meta = {
    description = "Proxy client based on ClashMeta, simple and easy to use";
    homepage = "https://github.com/chen08209/FlClash";
    license = with lib.licenses; [ gpl3Plus ];
    maintainers = with lib.maintainers; [ VZstless ];
  };

  # ------------------------------------------------------------------
  # 0.8.93 起上游不再用 CMake 安装内核，改成 Dart native-assets hook
  # （plugins/setup/hook/build.dart）在 flutter build 期间现编三样东西：
  #   libclash/linux/FlClashCore           Go 内核
  #   libclash/linux/FlClashHelperService  Rust Helper（services/helper）
  #   libclash/linux/manifest.json         {"coreSha256":"..."}  —— Helper 也内嵌这个值
  # 另外 plugins/rust_api/rust 出 librust_api.so。
  # nix 沙箱里没网，hook 跑不动，所以下面全部改成独立 derivation 预构建。
  # ------------------------------------------------------------------

  # Go 内核
  core = buildGo127Module {
    pname = "core";
    inherit version src meta;

    modRoot = "core";

    # 0.9.0 起 core/go.mod 要求 go >= 1.27.0。注意不能用 buildGoModule 再传
    # go = go_1_27：module.nix 的 go 是 callPackage 已经填好的函数参数，
    # 传进去只会变成 derivation 属性，vendor FOD 仍然用默认的 1.26.7。

    vendorHash = "sha256-9rvq8PtXDxwORx80GBQa4CHIm2b3iDqWRkA55osiQl0=";

    env.CGO_ENABLED = 0;

    buildPhase = ''
      runHook preBuild

      mkdir -p $out/bin
      # 0.9.0 起 Clash.Meta 的主包从 core/ 根目录挪到了 ./cmd/core。
      # 继续 go build 根目录只会得到一个 ar 归档（!<arch>），helper 执行它
      # 会报 "syntax error near unexpected token"，GUI 等 IPC 等到超时。
      # 版本号也按上游 build_config.yaml 注入（上游 hook 用 -X 设这个符号）。
      coreVersion=$(sed -n 's/^core_version: *//p' ../build_config.yaml | head -n1)
      go build \
        -ldflags="-w -s -X github.com/metacubex/mihomo/constant.Version=$coreVersion" \
        -tags=with_gvisor \
        -o $out/bin/FlClashCore \
        ./cmd/core

      runHook postBuild
    '';
  };

  # 内核二进制的 sha256。Helper 会把它编进二进制（CORE_SHA256 环境变量），
  # manifest.json 里也是同一个值。现算，避免 IFD。
  coreSha256Cmd = ''
    sha256sum ${core}/bin/FlClashCore | cut -d' ' -f1 | tr -d '\n'
  '';

  # Rust Helper：FlClashHelperService
  helper = rustPlatform.buildRustPackage {
    pname = "flclash-helper";
    inherit version src meta;

    sourceRoot = "source/services/helper";

    # 0.9.x 更新了 helper 的 Cargo 依赖，cargoHash 已按 0.9.1 重算。
    cargoHash = "sha256-M7m+rs96S4CkQK/mnJ+5IcHXQKMl3Yp2bovdpwc+Nn4=";

    preBuild = ''
      export CORE_SHA256=$(${coreSha256Cmd})
      export CORE_NAME=FlClashCore
    '';

    postInstall = ''
      mv $out/bin/helper $out/bin/FlClashHelperService
    '';
  };

  # Rust API 库：librust_api.so（flutter_rust_bridge 的 cdylib）
  lock = lib.importJSON ./pubspec.lock.json;

  rustApi = rustPlatform.buildRustPackage {
    pname = "flclash-rust-api";
    inherit version src meta;

    sourceRoot = "source/plugins/rust_api/rust";

    # 同上：按 0.9.1 的 Cargo.lock 重算。
    cargoHash = "sha256-IWXqZxqjiV4frGpGeHSBvPPQWbr0tzzNDzp+9BQ0ZG4=";

    # crate-type = ["cdylib", "staticlib"]，默认 installPhase（cargoInstallHook）
    # 是按 bin 装的，这里只收编出来的 librust_api.so。
    # 用 find 而不是写死 target/release/：这个 crate 可能被上层 workspace 接管 target 目录。
    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      cp "$(find . -name 'librust_api.so' -type f | head -n1)" $out/lib/

      runHook postInstall
    '';
  };
in
flutter347.buildFlutterApplication {
  inherit pname version src;

  # nixpkgs 会拿 pubspec.lock 里的 `sdks.dart` 当作**根包**的 language version
  # （pkgs/build-support/dart/build-dart-application/generators.nix:73）。但 pub 写进
  # lock 的这个字段含义是"锁定后的依赖集要求的最低 SDK"（0.9.1 是 3.13.2），跟根包
  # 自己的语言版本不是一回事。上游 `flutter pub get` 用的是 pubspec.yaml 里的
  # `sdk: '>=3.10.0 <4.0.0'`，也就是 3.10。
  #
  # 0.8.x 时这个差异会直接编译失败（Dart 3.13 不接受形参上的 final 修饰）。
  # 0.9.1 重写主题后那段代码没了，但仍然按 pubspec.yaml 声明覆盖：
  # lock 里的字段本来就不是干这个用的，照抄会让语言的版本语义偏掉。
  # （该字段只用于此，改它不影响依赖解析；各依赖包的语言版本由 pub2nix 从各自的
  #   pubspec 单独读取。）
  pubspecLock = lock // {
    sdks = lock.sdks // {
      dart = ">=3.10.0 <4.0.0";
    };
  };

  gitHashes = lib.importJSON ./git-hashes.json;

  # nixpkgs 给一批 pub 包准备了「源码构建器」，但其中两个是给旧版写的，
  # 对当前的 +eol 空壳包完全不适用：
  #   sqlite3_flutter_libs 0.6.0+eol  /  sqlcipher_flutter_libs 0.7.0+eol
  # 这两个包的 pubspec 里没有任何 plugin / platform 声明，README 也写明
  # "Starting from version 0.6.0, this package no longer does anything" ——
  # 它们已经是纯 Dart 包。nixpkgs 的 builder 却要往包里塞/改 linux/CMakeLists.txt，
  # 于是构建时报：
  #   cp: cannot create regular file 'linux/CMakeLists.txt': No such file or directory
  # 这里回退成默认行为（原样用 src），跟其它纯 Dart 包一样处理。
  # 可用的扩展点见 pkgs/build-support/dart/pub2nix/pubspec-lock.nix:137。
  #
  # sqlite3 不用自持了：nixpkgs 的构建器已登记 _3_7_0（本包锁的版本），用默认的。
  customSourceBuilders = {
    sqlite3_flutter_libs = { src, ... }: src;
    sqlcipher_flutter_libs = { src, ... }: src;
  };

  nativeBuildInputs = [
    copyDesktopItems
    autoPatchelfHook
    imagemagick
  ];

  buildInputs = [
    keybinder3
    libayatana-appindicator
    # 0.9.0 起 linux/CMakeLists.txt 直接 pkg_check_modules(X11 REQUIRED)
    libx11
  ];

  flutterBuildFlags = [ "--dart-define=APP_ENV=stable" ];

  # flutter_rust_bridge 的默认加载配置是 ExternalLibraryLoaderConfig(stem: 'rust_api')，
  # 也就是用**裸文件名** DynamicLibrary.open('librust_api.so') 去找库；dlopen 对裸名字
  # 只搜索「调用方」的 DT_RPATH/DT_RUNPATH 和 LD_LIBRARY_PATH。跑起来的调用方是 Flutter
  # 引擎 / libapp.so，它们都没有指向 bundle lib/ 的 RUNPATH（autoPatchelfHook 只给主程序
  # 设了），于是运行时报：
  #   Invalid argument(s): Failed to load dynamic library 'librust_api.so': 没有那个文件或目录
  # dartFixupHook 支持 extraWrapProgramArgs，用它给 bin/ 里的包装脚本补上 LD_LIBRARY_PATH。
  extraWrapProgramArgs = ''--suffix LD_LIBRARY_PATH : "$out/app/flclash/lib"'';

  desktopItems = [
    (makeDesktopItem {
      # 文件名必须匹配上游写死的 APPLICATION_ID（linux/CMakeLists.txt:
      # set(APPLICATION_ID "com.follow.clash")）。my_application.cc 启动时
      # g_set_prgname(APPLICATION_ID)，Wayland 的 app_id 与 X11 的 WM_CLASS
      # 都由程序名派生；桌面环境靠它匹配 .desktop 文件名来取窗口/任务栏图标，
      # 文件叫 flclash.desktop 就永远对不上，只显示通用图标。
      # StartupWMClass 再兜底 X11 的 WM_CLASS 匹配。
      name = "com.follow.clash";
      exec = "FlClash %U";
      icon = "flclash";
      genericName = "FlClash";
      desktopName = "FlClash";
      categories = [ "Network" ];
      keywords = [
        "FlClash"
        "Clash"
        "ClashMeta"
        "Proxy"
      ];
      startupWMClass = "com.follow.clash";
      startupNotify = true;
    })
  ];

  postPatch = ''
    # 关掉两个 Dart native-assets hook。
    # 0.8.93 起 Go 内核 / Rust Helper / rust_api 库都由 hook 在 flutter build 期间现编，
    # 而 nix 沙箱没有网络（cargo 拉不到 crates）。置 false 后 CoreBuilder 只记一行日志
    # 就返回，不报错，正好让我们用上面预构建好的产物顶上。
    # 注意 rust_api 也必须关：否则它仍然会去 cargo build。
    substituteInPlace pubspec.yaml \
      --replace-fail "      build_assets: true" "      build_assets: false"

    # 不再需要动 lib/common/system.dart：0.8.93 起 checkIsAdmin() 在
    # hasHelperService（Linux + systemd + 非 AppImage）为真时直接返回
    # helperClient.readiness()，那套 stat + setuid 的检查根本走不到，
    # 提权交给 NixOS 模块起的 flclash-helper 服务。
  '';

  preBuild = ''
    # hook 关了，libclash/linux 下的产物由这里提供（对应上游 writeCoreManifest 的格式）
    mkdir -p libclash/linux
    cp ${core}/bin/FlClashCore libclash/linux/FlClashCore
    cp ${helper}/bin/FlClashHelperService libclash/linux/FlClashHelperService
    printf '{"coreSha256":"%s"}\n' "$(${coreSha256Cmd})" > libclash/linux/manifest.json
  '';

  postInstall = ''
    mkdir -p $out/share/icons/hicolor/512x512/apps
    magick assets/images/icon.png -resize 512x512 $out/share/icons/hicolor/512x512/apps/flclash.png

    # rust_api 的 hook 也关了，动态库自己放进 bundle 的 lib/（在 rpath 上）
    for libdir in "$out"/app/*/lib; do
      install -Dm755 ${rustApi}/lib/librust_api.so "$libdir/librust_api.so"
    done

    # 内核保持原样 —— 0.8.93 起它由 flclash-helper（root systemd 服务）启动，
    # 不再需要 setuid 包装程序，也不需要替换成符号链接。

    # Flutter builder 的 installPhase 会把 bundle 顶层的**所有**普通文件软链进 bin/
    # （`for f in $(find $out/app/$pname -maxdepth 1 -type f); do ln -s ...`），
    # manifest.json 也跟着进了 bin/。而 dartFixupHook 会对 bin/ 下每个条目跑
    # wrapProgramShell，碰到非可执行文件直接 die：
    #   Cannot wrap '.../bin/manifest.json' because it is not an executable file
    # 真身留在 app/flclash/ 下（应用也是从可执行文件旁边读它），删掉这个多余链接。
    rm -f "$out/bin/manifest.json"
  '';

  passthru = {
    inherit core helper rustApi;
    updateScript = ./update.sh;
  };

  meta = meta // {
    mainProgram = "FlClash";
    platforms = lib.platforms.linux;
  };
}
