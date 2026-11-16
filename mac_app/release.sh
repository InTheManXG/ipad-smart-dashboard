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
cd "$root"
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  printf '%s\n' '请先提交已验证的源码，再从干净工作区创建发行包。' >&2
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
spctl --assess --type execute --verbose=4 "$app"
archive="iPad-Control-$version-macos-arm64.zip"
mkdir -p "$output"
ditto -c -k --keepParent --sequesterRsrc "$app" "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > SHA256SUMS)
printf '已生成公证发行包：%s\n' "$output/$archive"
