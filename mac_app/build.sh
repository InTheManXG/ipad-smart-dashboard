#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/.build/iPad 控制台.app"
contents="$app/Contents"
# 固定证书身份，避免更新二进制后临时签名指纹变化导致钥匙串反复授权。
signing_identity="YOUR_SIGNING_IDENTITY"
if ! security find-identity -v -p codesigning | grep -Fq "$signing_identity"; then
  printf '%s\n' '缺少指定的 Apple Development 签名证书，请恢复证书和私钥；不允许退回临时签名。' >&2
  exit 1
fi
mkdir -p "$contents/MacOS" "$contents/Resources" "$root/.build/control.iconset"
# 所有运行资源都装进包内；构建路径不会进入 App 配置。
if [ -d "$contents/Resources/MediaAdapter" ]; then chmod -R u+w "$contents/Resources/MediaAdapter"; fi
cp -R "$root/mac_app/vendor/MediaAdapter" "$contents/Resources/"
chmod -R u+w "$contents/Resources/MediaAdapter"
install_name_tool -id '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' "$contents/Resources/MediaAdapter/MediaRemoteAdapter.framework/MediaRemoteAdapter"
codesign --force --sign "$signing_identity" "$contents/Resources/MediaAdapter/MediaRemoteAdapter.framework"
cp -R "$root/web" "$contents/Resources/"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""; if [ "$scale" = 2 ]; then suffix="@2x"; fi
    sips -z "$((size * scale))" "$((size * scale))" "$root/mac_app/assets/app-icon.png" --out "$root/.build/control.iconset/icon_${size}x${size}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$root/.build/control.iconset" -o "$contents/Resources/AppIcon.icns"
xcrun swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$root/.build/swift-cache" -target arm64-apple-macosx13.0 \
  "$root/mac_app/ConsoleActions.swift" "$root/mac_app/LocalPairing.swift" "$root/mac_app/NativeCore.swift" "$root/mac_app/CodexCollector.swift" "$root/mac_app/NativeMusic.swift" \
  "$root/mac_app/NativeServer.swift" "$root/mac_app/NativeMain.swift" -o "$contents/MacOS/iPadService"
xcrun swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$root/.build/swift-cache" -target arm64-apple-macosx13.0 \
  "$root/mac_app/UserAgent.swift" "$root/mac_app/ConsoleOrder.swift" "$root/mac_app/ConsoleSettings.swift" "$root/mac_app/App.swift" -o "$contents/MacOS/iPadControl"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.iamxg.ipad-control</string>
<key>CFBundleName</key><string>iPad 控制台</string>
<key>CFBundleDisplayName</key><string>iPad 控制台</string>
<key>CFBundleExecutable</key><string>iPadControl</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$signing_identity" --identifier com.iamxg.ipad-control.service "$contents/MacOS/iPadService"
codesign --force --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
