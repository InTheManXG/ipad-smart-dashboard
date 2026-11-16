#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/.build/iPad 控制台.app"
app_version="${APP_VERSION:-0.1.0-beta.2}"
deployment_target="13.0"
app_build="${APP_BUILD:-1}"
configuration="${BUILD_CONFIGURATION:-development}"
signing_identity="${SIGNING_IDENTITY:--}"

if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || [[ ! "$app_build" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' 'APP_VERSION 必须是语义版本，APP_BUILD 必须是正整数。' >&2
  exit 1
fi
if [[ "$configuration" != development && "$configuration" != release ]]; then
  printf '%s\n' 'BUILD_CONFIGURATION 仅支持 development 或 release。' >&2
  exit 1
fi
resolved_identity=""
if [[ "$signing_identity" != - ]]; then
  identities="$(security find-identity -v -p codesigning)"
  if [[ "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    resolved_identity="$(printf '%s\n' "$identities" | grep -iF " $signing_identity " | sed -n 's/.*"\([^"]*\)".*/\1/p' || true)"
  else
    resolved_identity="$(printf '%s\n' "$identities" | awk -F '"' -v wanted="$signing_identity" '$2 == wanted {print $2}')"
  fi
  if [[ -z "$resolved_identity" ]]; then
    printf '%s\n' '找不到 SIGNING_IDENTITY 对应的有效证书和私钥；不会自动降级签名。' >&2
    exit 1
  fi
fi
if [[ "$configuration" == release && "$resolved_identity" != 'Developer ID Application:'* ]]; then
  printf '%s\n' '正式发行必须设置 Developer ID Application 签名身份，不接受开发证书或临时签名。' >&2
  exit 1
fi
if [[ "$configuration" == release ]]; then
  for notice in LICENSE THIRD_PARTY_NOTICES.md; do
    if [[ ! -f "$root/$notice" ]]; then printf '发行缺少许可证文件：%s\n' "$notice" >&2; exit 1; fi
  done
fi
# 不能只降低 Info.plist 声明；预编译组件也必须支持同一最低系统。
for binary in "$root/mac_app/vendor/MediaAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" "$root/mac_app/vendor/MediaAdapter/MediaRemoteAdapterTestClient"; do
  if [[ "$(xcrun lipo -archs "$binary")" != arm64 ]]; then
    printf '%s\n' '媒体组件必须是 arm64 架构。' >&2; exit 1
  fi
  build_info="$(xcrun vtool -show-build "$binary")"
  if ! awk -v target="$deployment_target" '
    $1 == "platform" { count++; platform = $2 }
    $1 == "minos" { minimum = $2 }
    END {
      if (count != 1 || platform != "MACOS" || minimum !~ /^[0-9]+(\.[0-9]+)*$/) exit 1
      split(minimum, actual, "."); split(target, expected, ".")
      for (i = 1; i <= 3; i++) {
        if (actual[i] + 0 > expected[i] + 0) exit 1
        if (actual[i] + 0 < expected[i] + 0) exit 0
      }
    }' <<< "$build_info"; then
    printf '媒体组件的最低系统不支持 macOS %s，拒绝打包。\n' "$deployment_target" >&2; exit 1
  fi
done
printf '构建 %s (%s)，模式：%s，签名：%s\n' "$app_version" "$app_build" "$configuration" "${resolved_identity:-ad-hoc（仅本机开发）}" >&2
mkdir -p "$root/.build"
stage="$(mktemp -d "$root/.build/app-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
contents="$stage/iPad 控制台.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$stage/control.iconset"
# 在新目录组装，避免旧构建残留资源或本机 .DS_Store 进入发行包。
rsync -a --exclude '.DS_Store' "$root/mac_app/vendor/MediaAdapter" "$contents/Resources/"
chmod -R u+w "$contents/Resources/MediaAdapter"
install_name_tool -id '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' "$contents/Resources/MediaAdapter/MediaRemoteAdapter.framework/MediaRemoteAdapter"
rsync -a --exclude '.DS_Store' "$root/web" "$contents/Resources/"
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
  if [[ -f "$root/$notice" ]]; then cp "$root/$notice" "$contents/Resources/$notice"; fi
done
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""; if [[ "$scale" = 2 ]]; then suffix="@2x"; fi
    sips -z "$((size * scale))" "$((size * scale))" "$root/mac_app/assets/app-icon.png" --out "$stage/control.iconset/icon_${size}x${size}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$stage/control.iconset" -o "$contents/Resources/AppIcon.icns"
xcrun swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$root/.build/swift-cache" -target "arm64-apple-macosx$deployment_target" \
  "$root/mac_app/ConsoleActions.swift" "$root/mac_app/LocalPairing.swift" "$root/mac_app/NativeCore.swift" "$root/mac_app/CodexCollector.swift" "$root/mac_app/NativeMusic.swift" \
  "$root/mac_app/NativeServer.swift" "$root/mac_app/NativeMain.swift" -o "$contents/MacOS/iPadService"
xcrun swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$root/.build/swift-cache" -target "arm64-apple-macosx$deployment_target" \
  "$root/mac_app/UserAgent.swift" "$root/mac_app/ConsoleOrder.swift" "$root/mac_app/ConsoleSettings.swift" "$root/mac_app/App.swift" -o "$contents/MacOS/iPadControl"
cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.iamxg.ipad-control</string>
<key>CFBundleName</key><string>iPad 控制台</string>
<key>CFBundleDisplayName</key><string>iPad 控制台</string>
<key>CFBundleExecutable</key><string>iPadControl</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${app_version%%-*}</string>
<key>CFBundleVersion</key><string>$app_build</string>
<key>CFBundleGetInfoString</key><string>$app_version</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>$deployment_target</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
sign_options=(--force --sign "$signing_identity")
if [[ "$configuration" == release ]]; then sign_options+=(--options runtime --timestamp); fi
# 从内到外签名，包含媒体子进程；不通过 --deep 掩盖未签名的嵌套代码。
codesign "${sign_options[@]}" "$contents/Resources/MediaAdapter/MediaRemoteAdapter.framework"
codesign "${sign_options[@]}" "$contents/Resources/MediaAdapter/MediaRemoteAdapterTestClient"
codesign "${sign_options[@]}" --identifier com.iamxg.ipad-control.service "$contents/MacOS/iPadService"
codesign "${sign_options[@]}" "$stage/iPad 控制台.app"
codesign --verify --deep --strict "$stage/iPad 控制台.app"
if [[ -L "$app" ]]; then printf '%s\n' '构建输出不能是符号链接。' >&2; exit 1; fi
rm -rf "$app"
mv "$stage/iPad 控制台.app" "$app"
printf '%s\n' "$app"
