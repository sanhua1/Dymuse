#!/bin/sh
# 构建 macOS Release，并用固定的 Apple Development 证书重新签名。
# 默认的临时（ad-hoc）签名每次构建都不同，钥匙串里存的登录凭证会因此反复弹出授权窗口，
# “始终允许”也不会生效；用同一个证书签名后，授权一次即可长期有效。
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/development/flutter/bin:$PATH"
# 用 DYMUSE_SIGN_IDENTITY 指定你自己的签名证书（`security find-identity -v -p codesigning` 可查），
# 例如：DYMUSE_SIGN_IDENTITY="Apple Development: 你的名字 (XXXXXXXXXX)" tool/build_mac.sh
# 不指定时保留 Flutter 默认的临时签名，仍可运行，但钥匙串授权会每次构建都重新询问。
flutter build macos --release --no-pub
APP="build/macos/Build/Products/Release/Dymuse.app"
if [ -n "$DYMUSE_SIGN_IDENTITY" ]; then
  codesign --force --deep --sign "$DYMUSE_SIGN_IDENTITY" \
    --entitlements macos/Runner/Release.entitlements "$APP"
  codesign --verify --deep --strict "$APP"
  codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier"
else
  echo "未设置 DYMUSE_SIGN_IDENTITY，使用临时签名。"
fi
