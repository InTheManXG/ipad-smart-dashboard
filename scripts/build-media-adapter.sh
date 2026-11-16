#!/bin/bash
set -euo pipefail

expected_commit=e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6
if [[ $# != 2 ]]; then
  printf '%s\n' '用法：bash scripts/build-media-adapter.sh 上游源码目录 新的输出目录' >&2
  exit 1
fi
source_dir="$(cd "$1" && pwd)"
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$expected_commit" ]] ||
   [[ -n "$(git -C "$source_dir" status --porcelain)" ]]; then
  printf '上游源码必须是未修改的 mediaremote-adapter v0.7.7，提交 %s。\n' "$expected_commit" >&2
  exit 1
fi
if [[ -e "$2" || -L "$2" ]]; then
  printf '输出目录已存在，拒绝覆盖：%s\n' "$2" >&2
  exit 1
fi
mkdir -p "$(dirname "$2")"
output="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
stage="$(mktemp -d "$(dirname "$output")/.media-adapter.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
adapter="$stage/MediaAdapter"
framework="$adapter/MediaRemoteAdapter.framework"
resources="$framework/Versions/A/Resources"
mkdir -p "$resources" "$framework/Versions/A/Headers"

# 从锁定源码的构建声明读取版本和标识，不依赖维护者本机的旧产物。
cmake="$source_dir/CMakeLists.txt"
major="$(awk '$1 == "set(ADAPTER_VERSION_MAJOR" {gsub(/\)/, "", $2); print $2}' "$cmake")"
minor="$(awk '$1 == "set(ADAPTER_VERSION_MINOR" {gsub(/\)/, "", $2); print $2}' "$cmake")"
patch="$(awk '$1 == "set(ADAPTER_VERSION_PATCH" {gsub(/\)/, "", $2); print $2}' "$cmake")"
identifier="$(awk '/MACOSX_FRAMEWORK_IDENTIFIER/ {getline; gsub(/["[:space:]]/, ""); gsub(/\$\{MEDIAREMOTEADAPTER_FRAMEWORK_NAME\}/, "MediaRemoteAdapter"); print; exit}' "$cmake")"
version="$major.$minor.$patch"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$identifier" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf '%s\n' '无法从上游 CMakeLists.txt 读取框架版本或标识。' >&2
  exit 1
fi
cat > "$resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$major.$minor</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST
cp "$source_dir/LICENSE" "$adapter/LICENSE"
cp "$source_dir/bin/mediaremote-adapter.pl" "$adapter/mediaremote-adapter.pl"
cp "$source_dir/include/MediaRemoteAdapter.h" "$framework/Versions/A/Headers/"
ln -s A "$framework/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$framework/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$framework/Resources"
ln -s Versions/Current/Headers "$framework/Headers"

sources=()
while IFS= read -r source; do sources+=("$source_dir/$source"); done < <(
  awk '/^set\(ADAPTER_SOURCES/ {inside=1; next} inside {last=/\)/; gsub(/^[[:space:]]+|[)[:space:]]+$/, ""); if (length) print; if (last) exit}' "$cmake"
)
sdk="$(xcrun --show-sdk-path)"
# 明确编译目标，不能通过修改 load command 假装支持较旧系统。
options=(-target arm64-apple-macosx13.0 -isysroot "$sdk" -O2 -fobjc-arc -Werror=unguarded-availability-new)
xcrun clang "${options[@]}" -fvisibility=default -I "$source_dir/include" -I "$source_dir/src" \
  -dynamiclib "${sources[@]}" -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' \
  -current_version "$version" -compatibility_version "$version" -o "$framework/Versions/A/MediaRemoteAdapter"
xcrun clang "${options[@]}" -I "$source_dir/src/test" \
  "$source_dir/src/test/main.m" "$source_dir/src/test/NowPlayingTest.m" \
  -framework Foundation -framework MediaPlayer -o "$adapter/MediaRemoteAdapterTestClient"

# 临时签名只保证本机构建完整；正式发行仍由 App 打包流程重新签名及公证。
codesign --force --sign - "$framework"
codesign --force --sign - "$adapter/MediaRemoteAdapterTestClient"
codesign --verify --deep --strict "$framework"
codesign --verify --strict "$adapter/MediaRemoteAdapterTestClient"
for binary in "$framework/Versions/A/MediaRemoteAdapter" "$adapter/MediaRemoteAdapterTestClient"; do
  [[ "$(xcrun lipo -archs "$binary")" == arm64 ]]
  xcrun vtool -show-build "$binary" | awk '
    $1 == "platform" {platform=$2}
    $1 == "minos" {minimum=$2; count++}
    END {exit !(platform == "MACOS" && minimum == "13.0" && count == 1)}'
done
mv "$adapter" "$output"
printf '已构建媒体组件：%s（%s，arm64 / macOS 13.0；未完成真机兼容验收）\n' "$output" "$expected_commit"
