#!/bin/bash
# 更新只指向本版本的最终 ZIP，避免 latest 切换时下载到另一份安装包。
set +x
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
app="${2:-}"
archive="${3:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || [[ ! -d "$app" || ! -f "$archive" || "$archive" != *.zip ]]; then
  printf '%s\n' '用法：bash mac_app/generate-appcast.sh 版本号 "App 路径" "最终 ZIP 路径"' >&2
  exit 1
fi
tools="$root/.build/sparkle/bin"
for tool in generate_appcast generate_keys sign_update; do
  [[ -x "$tools/$tool" ]] || { printf '%s\n' '缺少构建时固定版本的 Sparkle 工具。' >&2; exit 1; }
done
public_key="$(tr -d '\r\n' < "$root/mac_app/update-public-key.txt")"
plist="$app/Contents/Info.plist"
[[ "$(plutil -extract SUPublicEDKey raw -o - "$plist")" == "$public_key" ]] || { printf '%s\n' 'App 内置更新公钥不匹配，拒绝签署更新。' >&2; exit 1; }
[[ "$(plutil -extract CFBundleGetInfoString raw -o - "$plist")" == "$version" ]] || { printf '%s\n' '更新版本与 App 不一致。' >&2; exit 1; }
[[ "$(plutil -extract SURequireSignedFeed raw -o - "$plist")" == true ]] || { printf '%s\n' 'App 必须验证更新源签名。' >&2; exit 1; }
output="$(dirname "$archive")/appcast.xml"
[[ ! -e "$output" && ! -L "$output" ]] || { printf '%s\n' 'appcast.xml 已存在，拒绝覆盖。' >&2; exit 1; }
account=com.iamxg.ipad-control.updates
if [[ "${CI:-}" == true && -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' 'GitHub 打包缺少 SPARKLE_PRIVATE_KEY，拒绝发布未签名更新。' >&2
  exit 1
fi
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  # 先独立校验私钥和公钥，避免工具将格式错误的秘密带入错误日志。
  SPARKLE_EXPECTED_PUBLIC_KEY="$public_key" xcrun swift -module-cache-path "$root/.build/swift-cache" - <<'SWIFT'
import Foundation
import CryptoKit
let env = ProcessInfo.processInfo.environment
guard let text = env["SPARKLE_PRIVATE_KEY"], let seed = Data(base64Encoded: text), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
      key.publicKey.rawRepresentation.base64EncodedString() == env["SPARKLE_EXPECTED_PUBLIC_KEY"] else {
    fputs("更新私钥格式无效或与内置公钥不匹配。\n", stderr); exit(1)
}
SWIFT
  signing=(--ed-key-file -)
else
  [[ "$("$tools/generate_keys" --account "$account" -p)" == "$public_key" ]] || { printf '%s\n' '钥匙串更新密钥与内置公钥不匹配。' >&2; exit 1; }
  signing=(--account "$account")
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/ipad-appcast.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp -p "$archive" "$work/"
options=(--maximum-deltas 0 --download-url-prefix "https://github.com/InTheManXG/ipad-smart-dashboard/releases/download/v$version/" --link "https://github.com/InTheManXG/ipad-smart-dashboard/releases/tag/v$version")
if [[ "$version" == *-* ]]; then options+=(--channel beta); fi
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" "${signing[@]}" "${options[@]}" "$work"
  printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" "${signing[@]}" --verify "$work/appcast.xml"
else
  "$tools/generate_appcast" "${signing[@]}" "${options[@]}" "$work"
  "$tools/sign_update" "${signing[@]}" --verify "$work/appcast.xml"
fi
python3 - "$work/appcast.xml" "$archive" "$version" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

feed, archive, version = sys.argv[1:]
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1, '更新源必须只有本次完整安装包'
item = items[0]
enclosure = item.find('enclosure')
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert enclosure is not None and enclosure.get(sparkle + 'edSignature'), '更新包缺少 EdDSA 签名'
assert enclosure.get('url') == f'https://github.com/InTheManXG/ipad-smart-dashboard/releases/download/v{version}/{Path(archive).name}', '更新地址不是本次版本的安装包'
assert enclosure.get('length') == str(Path(archive).stat().st_size), '更新包大小不匹配'
assert item.findtext(sparkle + 'channel') == ('beta' if '-' in version else None), '稳定版与预发布通道不匹配'
PY
cp "$work/appcast.xml" "$output"
printf '已生成并验证更新源：%s\n' "$output"
