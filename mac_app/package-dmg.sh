#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 2 || ! -d "$1" || "$(basename "$1")" != 'iPad 控制台.app' || "$2" != *.dmg ]]; then
  printf '%s\n' '用法：bash mac_app/package-dmg.sh "iPad 控制台.app 的路径" "输出路径.dmg"' >&2
  exit 1
fi
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
if [[ -e "$output" || -L "$output" ]]; then
  printf 'DMG 已存在，拒绝覆盖：%s\n' "$output" >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
version="$(plutil -extract CFBundleGetInfoString raw -o - "$app/Contents/Info.plist")"
# 挂载目录不放进调用者的暂存目录，避免外层清理误删尚未卸载的卷。
work="$(mktemp -d "${TMPDIR:-/tmp}/ipad-dmg.XXXXXX")"
mounted=""
cleanup() {
  # 卸载失败时保留临时目录，避免递归清理仍然挂载的镜像内容。
  if [[ -n "$mounted" ]] && ! hdiutil detach "$mounted"; then
    printf '请手动推出镜像后清理：%s\n' "$work" >&2
    return 1
  fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir "$work/source" "$work/mounted" "$work/copied"
ditto "$app" "$work/source/iPad 控制台.app"
ln -s /Applications "$work/source/Applications"
# 固定图标位置和浅蓝底色随包保存，CI 不需要操作 Finder 或安装布局生成库。
cp "$root/mac_app/assets/dmg-layout.DS_Store" "$work/source/.DS_Store"
cat > "$work/source/安装说明.txt" <<NOTES
iPad 控制台 $version

将左侧「iPad 控制台」拖入右侧「Applications（应用程序）」即可安装。
请从「应用程序」打开 App，不要直接运行镜像内的 App；安装后推出此镜像。

升级前，在旧版菜单选择「退出 iPad 控制台（停止后台服务）」，再替换完整 App。
配置和钥匙串保存在 App 之外，升级时请保留。

首次打开前，请阅读本版本发行页的签名状态和安装说明：
https://github.com/InTheManXG/ipad-smart-dashboard/releases
NOTES
hdiutil create -quiet -format UDZO -fs HFS+ -volname 'iPad 控制台' -srcfolder "$work/source" "$work/installer.dmg"
hdiutil verify "$work/installer.dmg"
mounted="$work/mounted"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mounted" "$work/installer.dmg"
[[ "$(readlink "$mounted/Applications")" == /Applications ]]
cmp "$root/mac_app/assets/dmg-layout.DS_Store" "$mounted/.DS_Store"
[[ -s "$mounted/安装说明.txt" ]]
# 验证从成品卷复制出来的 App，覆盖真实拖动安装时的文件完整性和签名。
ditto "$mounted/iPad 控制台.app" "$work/copied/iPad 控制台.app"
codesign --verify --deep --strict "$work/copied/iPad 控制台.app"
[[ "$(plutil -extract CFBundleGetInfoString raw -o - "$work/copied/iPad 控制台.app/Contents/Info.plist")" == "$version" ]]
# 按文件校验和与链接目标比较，不跟随媒体框架内部的目录链接。
comparison="$(rsync -nrcil --delete "$app/" "$work/copied/iPad 控制台.app/")"
[[ -z "$comparison" ]]
hdiutil detach "$mounted"
mounted=""
mv "$work/installer.dmg" "$output"
printf '已生成并验证 DMG：%s\n' "$output"
