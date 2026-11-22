#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-${APP_VERSION:-}}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  printf '%s\n' '未公证发行包需要有效版本号，例如：bash mac_app/package-preview.sh 0.1.0' >&2
  exit 1
fi
cd "$root"
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  printf '%s\n' '请先提交已验证的源码，再从干净工作区创建发行包。' >&2
  exit 1
fi
# 忽略规则不等于可以分发；资源目录中的本机私密文件也必须拒绝。
if [[ -n "$(git ls-files --others -- web mac_app/vendor/MediaAdapter mac_app/assets | sed '/\(^\|\/\)\.DS_Store$/d')" ]]; then
  printf '%s\n' '打包资源含未跟踪文件（包括被忽略的文件），请先移出本机配置和私密文件。' >&2
  exit 1
fi
if ! git tag --points-at HEAD | grep -Fxq "v$version"; then
  printf '当前提交缺少对应版本标签 v%s。\n' "$version" >&2
  exit 1
fi
output="$root/.build/previews/$version"
if [[ -e "$output" || -L "$output" ]]; then
  printf '发行包目录已存在，拒绝覆盖：%s\n' "$output" >&2
  exit 1
fi
for notice in LICENSE THIRD_PARTY_NOTICES.md docs/UNNOTARIZED_INSTALL.md; do
  if [[ ! -f "$root/$notice" ]]; then printf '发行包缺少说明文件：%s\n' "$notice" >&2; exit 1; fi
done
# 发行版本号不改变签名要求；缺证书不能降级，否则升级会改变钥匙串识别的身份。
if [[ ! "${SIGNING_IDENTITY:-}" =~ ^[[:xdigit:]]{40}$ ]]; then
  printf '%s\n' '发行包必须设置固定 Apple Development 证书的 SIGNING_IDENTITY SHA-1 指纹，不接受 ad-hoc 签名。' >&2
  exit 1
fi
export BUILD_CONFIGURATION=development SIGNING_IDENTITY APP_VERSION="$version" APP_BUILD="${APP_BUILD:-1}"
bash "$root/mac_app/build.sh"
app="$root/.build/iPad 控制台.app"
bash "$root/mac_app/check-development-signature.sh" "$app" "$SIGNING_IDENTITY"
if [[ "$(plutil -extract CFBundleGetInfoString raw -o - "$app/Contents/Info.plist")" != "$version" ]]; then
  printf '%s\n' '发行包版本与标签不一致。' >&2
  exit 1
fi
xcrun swift -module-cache-path "$root/.build/swift-cache" "$root/scripts/check-media.swift"
mkdir -p "$(dirname "$output")"
stage="$(mktemp -d "$root/.build/previews/.preview.XXXXXX")"
verification="$(mktemp -d "$root/.build/previews/.verify.XXXXXX")"
trap 'rm -rf "$stage" "$verification"' EXIT
archive="iPad-Control-$version-unnotarized-macos-arm64.zip"
image="iPad-Control-$version-unnotarized-macos-arm64.dmg"
bash "$root/mac_app/package-dmg.sh" "$app" "$stage/$image"
codesign --force --sign "$SIGNING_IDENTITY" "$stage/$image"
codesign --verify --strict "$stage/$image"
ditto -c -k --keepParent --sequesterRsrc "$app" "$stage/$archive"
# 验收下载后真正解压的成品，避免打包遗漏或损坏被原目录的检查掩盖。
ditto -x -k "$stage/$archive" "$verification"
unpacked="$verification/iPad 控制台.app"
for binary in MacOS/iPadControl MacOS/iPadService Resources/MediaAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter Resources/MediaAdapter/MediaRemoteAdapterTestClient; do
  [[ -f "$unpacked/Contents/$binary" ]]
done
bash "$root/mac_app/check-development-signature.sh" "$unpacked" "$SIGNING_IDENTITY"
[[ "$(plutil -extract CFBundleGetInfoString raw -o - "$unpacked/Contents/Info.plist")" == "$version" ]]
bash "$root/mac_app/generate-appcast.sh" "$version" "$unpacked" "$stage/$archive"
cp "$root/docs/UNNOTARIZED_INSTALL.md" "$stage/UNNOTARIZED_INSTALL.md"
(cd "$stage" && shasum -a 256 "$image" "$archive" appcast.xml UNNOTARIZED_INSTALL.md > SHA256SUMS)
mv "$stage" "$output"
printf '已生成未公证发行包：%s\n' "$output/$image"
