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
xcrun swift -module-cache-path "$root/.build/swift-cache" - "$work/appcast.xml" "$archive" "$version" <<'APPCAST_SWIFT'
import Foundation

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fail("更新源校验参数无效") }
let feed = URL(fileURLWithPath: CommandLine.arguments[1])
let archive = URL(fileURLWithPath: CommandLine.arguments[2])
let version = CommandLine.arguments[3]
guard let data = try? Data(contentsOf: feed),
      // Sparkle 生成 UTF-8 XML；解析前拒绝 DTD，避免先展开声明再执行校验。
      data.range(of: Data("<!DOCTYPE".utf8)) == nil,
      let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
      document.dtd == nil, let root = document.rootElement() else {
    fail("更新源 XML 无效或包含外部实体声明")
}
// 更新源只读取本地生成的内容；禁用外部实体，拒绝带 DTD 的文档。
let items = root.elements(forName: "channel").flatMap { $0.elements(forName: "item") }
guard items.count == 1 else { fail("更新源必须只有本次完整安装包") }
let item = items[0]
let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
guard let enclosure = item.elements(forName: "enclosure").first,
      let signature = enclosure.attribute(forLocalName: "edSignature", uri: sparkle)?.stringValue,
      !signature.isEmpty else { fail("更新包缺少 EdDSA 签名") }
let expectedURL = "https://github.com/InTheManXG/ipad-smart-dashboard/releases/download/v\(version)/\(archive.lastPathComponent)"
guard enclosure.attribute(forName: "url")?.stringValue == expectedURL else {
    fail("更新地址不是本次版本的安装包")
}
guard let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path),
      let size = attributes[.size] as? NSNumber,
      enclosure.attribute(forName: "length")?.stringValue == size.stringValue else {
    fail("更新包大小不匹配")
}
let channel = item.elements(forLocalName: "channel", uri: sparkle).first?.stringValue
guard channel == (version.contains("-") ? "beta" : nil) else {
    fail("稳定版与预发布通道不匹配")
}
APPCAST_SWIFT
cp "$work/appcast.xml" "$output"
printf '已生成并验证更新源：%s\n' "$output"
