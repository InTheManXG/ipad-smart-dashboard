#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-${APP_VERSION:-}}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*$ ]]; then
  printf '%s\n' '未公证测试包只接受预发布版本，例如：bash mac_app/package-preview.sh 0.1.0-beta.3' >&2
  exit 1
fi
cd "$root"
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  printf '%s\n' '请先提交已验证的源码，再从干净工作区创建测试包。' >&2
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
  printf '测试包目录已存在，拒绝覆盖：%s\n' "$output" >&2
  exit 1
fi
for notice in LICENSE THIRD_PARTY_NOTICES.md docs/UNNOTARIZED_INSTALL.md; do
  if [[ ! -f "$root/$notice" ]]; then printf '测试包缺少说明文件：%s\n' "$notice" >&2; exit 1; fi
done
# 测试包始终使用临时签名，不能继承外部证书配置而被误认为正式发行。
export BUILD_CONFIGURATION=development SIGNING_IDENTITY=- APP_VERSION="$version" APP_BUILD="${APP_BUILD:-1}"
bash "$root/mac_app/build.sh"
app="$root/.build/iPad 控制台.app"
codesign --verify --deep --strict "$app"
if ! codesign -dv "$app" 2>&1 | grep -Fxq 'Signature=adhoc'; then
  printf '%s\n' '测试包必须使用 ad-hoc 签名。' >&2
  exit 1
fi
if [[ "$(plutil -extract CFBundleGetInfoString raw -o - "$app/Contents/Info.plist")" != "$version" ]]; then
  printf '%s\n' '测试包版本与标签不一致。' >&2
  exit 1
fi
python3 "$root/scripts/check-media.py"
mkdir -p "$(dirname "$output")"
stage="$(mktemp -d "$root/.build/previews/.preview.XXXXXX")"
verification="$(mktemp -d "$root/.build/previews/.verify.XXXXXX")"
trap 'rm -rf "$stage" "$verification"' EXIT
archive="iPad-Control-$version-unnotarized-macos-arm64.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$stage/$archive"
# 验收下载后真正解压的成品，避免打包遗漏或损坏被原目录的检查掩盖。
ditto -x -k "$stage/$archive" "$verification"
unpacked="$verification/iPad 控制台.app"
for binary in MacOS/iPadControl MacOS/iPadService Resources/MediaAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter Resources/MediaAdapter/MediaRemoteAdapterTestClient; do
  [[ -f "$unpacked/Contents/$binary" ]]
done
codesign --verify --deep --strict "$unpacked"
[[ "$(plutil -extract CFBundleGetInfoString raw -o - "$unpacked/Contents/Info.plist")" == "$version" ]]
cp "$root/docs/UNNOTARIZED_INSTALL.md" "$stage/UNNOTARIZED_INSTALL.md"
(cd "$stage" && shasum -a 256 "$archive" UNNOTARIZED_INSTALL.md > SHA256SUMS)
mv "$stage" "$output"
printf '已生成未公证测试包（非正式发行）：%s\n' "$output/$archive"
