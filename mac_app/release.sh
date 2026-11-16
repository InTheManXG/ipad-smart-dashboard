#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-${APP_VERSION:-}}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  printf '%s\n' '用法：SIGNING_IDENTITY="Developer ID Application: …" NOTARY_KEYCHAIN_PROFILE=… bash mac_app/release.sh 0.1.0-beta.1' >&2
  exit 1
fi
if [[ -z "${SIGNING_IDENTITY:-}" || -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  printf '%s\n' '正式发行需要 SIGNING_IDENTITY 和已保存在钥匙串的 NOTARY_KEYCHAIN_PROFILE；不会产出未公证安装包。' >&2
  exit 1
fi
require_gatekeeper() {
  # 关闭系统评估时 assess 也可能返回成功，不能把这一结果当作发行验收。
  if [[ "$(spctl --status 2>/dev/null)" != 'assessments enabled' ]]; then
    printf '%s\n' 'Gatekeeper 未启用或状态无法确认，拒绝执行正式发行验收。' >&2
    exit 1
  fi
}
require_gatekeeper
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
export BUILD_CONFIGURATION=release APP_VERSION="$version" APP_BUILD="${APP_BUILD:-1}"
bash "$root/mac_app/build.sh"
app="$root/.build/iPad 控制台.app"
output="$root/.build/releases/$version"
if [[ -e "$output" ]]; then
  printf '发行目录已存在，拒绝混入上一次产物：%s\n' "$output" >&2
  exit 1
fi
submission="$(mktemp -d "$root/.build/notary.XXXXXX")"
trap 'rm -rf "$submission"' EXIT
ditto -c -k --keepParent --sequesterRsrc "$app" "$submission/submission.zip"
notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then notary_args+=(--keychain "$NOTARY_KEYCHAIN"); fi
xcrun notarytool submit "$submission/submission.zip" "${notary_args[@]}" --wait --output-format json > "$submission/result.json"
# submit 的进程退出成功不等于审核通过；只发布 Accepted 的结果。
if [[ "$(plutil -extract status raw -o - "$submission/result.json")" != Accepted ]]; then
  printf '%s\n' 'Apple 公证未通过，未生成可发布的归档。请用 notarytool log 检查本次提交。' >&2
  plutil -extract id raw -o - "$submission/result.json" >&2 || true
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
require_gatekeeper
spctl --assess --type execute --verbose=4 "$app"
archive="iPad-Control-$version-macos-arm64.zip"
mkdir -p "$output"
ditto -c -k --keepParent --sequesterRsrc "$app" "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > SHA256SUMS)
printf '已生成公证发行包：%s\n' "$output/$archive"
