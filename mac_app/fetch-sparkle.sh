#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/.build/sparkle"
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
archive="$cache/Sparkle-$version.tar.xz"
mkdir -p "$cache"
work="$(mktemp -d "$cache/.fetch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$work/download.tar.xz"
  mv "$work/download.tar.xz" "$archive"
fi
# 缓存与新下载都先验固定摘要，不能把下载地址或旧目录当作完整性证明。
if [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$checksum" ]]; then
  printf '%s\n' 'Sparkle 下载摘要不匹配，拒绝构建；请移除损坏缓存后重试。' >&2
  exit 1
fi
tar -xf "$archive" -C "$work" ./Sparkle.framework ./bin ./LICENSE
for item in Sparkle.framework bin LICENSE; do
  rm -rf "$cache/$item"
  mv "$work/$item" "$cache/$item"
done
printf '%s\n' "$cache"
