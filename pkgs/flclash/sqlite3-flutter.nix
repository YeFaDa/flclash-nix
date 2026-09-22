# 自持 sqlite3 的 pub 源码构建器，替代 nixpkgs 里那份。
#
# 背景：nixpkgs 从 44a9189（2026-09-21）起给 sqlite3 构建器加了 sqlcipher 支持
# （Dart 侧 3.5.0+ 把 fromGitHub() 换成了 LookupSystem()，运行时需要系统提供
# libsqlite3 / libsqlcipher）。但它把预编译 .so 的 sha256 按「版本号-架构」
# 硬编码成一张表，表里只登记了 _3_5_0。FlClash 锁的是 sqlite3 3.5.1，
# 查表落空 → eval 阶段直接 throw：
#   Unsupported version of pub 'sqlite3' ('sqlcipher' dependency '3.5.1')
# 上游 nixos-unstable 至今仍只有 _3_5_0，所以升级 nixpkgs 修不好。
#
# 这里把这层逻辑复制进本仓库自持，nixpkgs 怎么改都不再影响构建。
# 实测 3.5.0 与 3.5.1 的 libsqlcipher.x64.linux.so 二进制完全相同：
#   nix store prefetch-file https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.1/libsqlcipher.x64.linux.so
#   → sha256-GH+3MhYXTwWD7WmEHzc8wecYcaOcCXsy93UWiEjh6Eo=
# 因此 _3_5_1 与 _3_5_0 共用同一个哈希（即原报错信息里说的 "add an alias"）。
#
# 以后升级 FlClash 若带上新的 sqlite3 版本，这里会再次 throw，届时按提示补哈希：
#   nix store prefetch-file https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-<版本>/libsqlcipher.x64.linux.so
# 若哈希与已有版本相同，直接加一行别名即可。
{ stdenv, lib, writeScript, fetchurl, sqlite }:

{ version, src, ... }:

let
  sqlcipher =
    let
      system-alias = {
        x86_64-linux = "x64.linux";
      };
    in
    stdenv.mkDerivation {
      name = "libsqlcipher.so";
      src = fetchurl {
        url = "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${version}/libsqlcipher.${
          system-alias.${stdenv.hostPlatform.system} or (throw ''
            Unsupported system for pub 'sqlite3' ('sqlcipher' dependency)
            Please add the system alias mapping if it exists, note that you will also have to add used version hashes for that system below'')
        }.so";
        sha256 =
          {
            # 二进制与 3.5.0 相同，故共用哈希
            _3_5_0-x86_64-linux = "sha256-GH+3MhYXTwWD7WmEHzc8wecYcaOcCXsy93UWiEjh6Eo=";
            _3_5_1-x86_64-linux = "sha256-GH+3MhYXTwWD7WmEHzc8wecYcaOcCXsy93UWiEjh6Eo=";
          }
          .${"_" + (lib.replaceStrings [ "." ] [ "_" ] version) + "-" + stdenv.hostPlatform.system}
            or (throw ''
              Unsupported version of pub 'sqlite3' ('sqlcipher' dependency '${version}')
              Please add sha256 here. If the sha256
              is the same with existing versions, add an alias here.
            '');
      };
      unpackPhase = ":";
      installPhase = "mkdir -p $out/lib && cp $src $out/lib/libsqlcipher.so";
    };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "sqlite3";
  inherit version src;
  inherit (src) passthru;

  setupHook = writeScript "${finalAttrs.pname}-setup-hook" ''
    sqliteFixupHook() {
      runtimeDependencies+=('${lib.getLib sqlite}')
      ${lib.optionalString (lib.versionAtLeast version "3.5.0") "runtimeDependencies+=('${lib.getLib sqlcipher}')"}
    }

    preFixupHooks+=(sqliteFixupHook)
  '';

  postPatch =
    if lib.versionAtLeast version "3.5.0" then
      ''
        substituteInPlace lib/src/hook/compile/description.dart \
          --replace-fail "return fromGitHub(LibraryType.sqlite3);" "return LookupSystem('sqlite3');"

        substituteInPlace lib/src/hook/compile/description.dart \
          --replace-fail "return fromGitHub(LibraryType.sqlcipher);" "return LookupSystem('sqlcipher');"
      ''
    else
      lib.optionalString (lib.versionAtLeast version "3.2.0") ''
        substituteInPlace lib/src/hook/description.dart \
          --replace-fail "return PrecompiledFromGithubAssets(LibraryType.sqlite3);" "return LookupSystem('sqlite3');"
      '';

  installPhase = ''
    runHook preInstall

    cp --recursive . "$out"

    runHook postInstall
  '';
})
