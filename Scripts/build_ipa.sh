#!/bin/bash
# 本地（Mac）一键打出未签名 IPA —— 无开发者账号也能用
# 用法：cd PhotoSpaceMaster && bash Scripts/build_ipa.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 0/4 选择最新版 Xcode（工程格式需 Xcode 16+）"
if [ -d "/Applications/Xcode.app" ]; then
  sudo xcode-select -s "/Applications/Xcode.app" 2>/dev/null || true
fi
xcodebuild -version

echo "==> 1/4 生成 Xcode 工程"
command -v xcodegen >/dev/null 2>&1 || { echo "请先安装: brew install xcodegen"; exit 1; }
xcodegen generate

echo "==> 2/4 编译（未签名）"
xcodebuild \
  -project PhotoSpaceMaster.xcodeproj \
  -scheme PhotoSpaceMaster \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

echo "==> 3/4 打包 IPA"
APP_PATH=$(find build/Build/Products -type d -name "*.app" | head -n 1)
rm -rf Payload
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -qry PhotoSpaceMaster-unsigned.ipa Payload

echo "==> 4/4 完成: $(pwd)/PhotoSpaceMaster-unsigned.ipa"
