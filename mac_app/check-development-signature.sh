#!/bin/bash
set -euo pipefail
if [[ $# != 2 || ! "$2" =~ ^[[:xdigit:]]{40}$ ]]; then
  printf '%s\n' '用法：bash mac_app/check-development-signature.sh "App 路径" "Apple Development 证书 SHA-1 指纹"' >&2
  exit 1
fi
app="$1"
fingerprint="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
work="$(mktemp -d "${TMPDIR:-/tmp}/ipad-signature.XXXXXX")"
trap 'rm -rf "$work"' EXIT
index=0
for item in "$app" "$app/Contents/MacOS/iPadService" \
  "$app/Contents/Resources/MediaAdapter/MediaRemoteAdapter.framework" \
  "$app/Contents/Resources/MediaAdapter/MediaRemoteAdapterTestClient"; do
  codesign --verify --strict "$item"
  info="$(codesign -dvv "$item" 2>&1)"
  if ! grep -q '^Authority=Apple Development:' <<< "$info"; then
    printf '%s\n' '测试包必须使用 Apple Development 证书签名。' >&2; exit 1
  fi
  # 名称和 Team ID 不能唯一标识证书，逐个比较实际签名叶证书的指纹。
  codesign -d --extract-certificates="$work/cert-$index-" "$item" 2>/dev/null
  actual="$(shasum -a 1 "$work/cert-$index-0" | awk '{print toupper($1)}')"
  if [[ "$actual" != "$fingerprint" ]]; then
    printf '%s\n' '组件签名证书与固定指纹不一致，拒绝发布。' >&2; exit 1
  fi
  if [[ "$index" == 0 || "$index" == 1 ]]; then
    identifier=com.iamxg.ipad-control
    if [[ "$index" == 1 ]]; then identifier+=.service; fi
    grep -Fxq "Identifier=$identifier" <<< "$info"
    requirement="$(codesign -d -r- "$item" 2>&1)"
    # 更新应依靠证书与标识识别应用，不能退回随每次构建变化的代码哈希。
    [[ "$requirement" == *'designated => '* && "$requirement" != *cdhash* ]]
  fi
  index=$((index + 1))
done
codesign --verify --deep --strict "$app"
printf '%s\n' 'App、后台和媒体组件的固定开发证书验证通过。'
