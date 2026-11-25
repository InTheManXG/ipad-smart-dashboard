#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p .build
stage="$(mktemp -d "$root/.build/service-memory.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
contents="$stage/MemoryTest.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources/MediaAdapter"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>MemoryTest</string><key>CFBundleIdentifier</key><string>com.iamxg.ipad-memory-test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
# 只执行读取；大 JSON 放大临时对象积压，不接触真实播放器、用户配置或网络。
cat > "$contents/Resources/MediaAdapter/mediaremote-adapter.pl" <<'PERL'
use strict;
use warnings;
use FindBin;
die "unexpected media command" unless @ARGV == 5 && $ARGV[2] eq 'get' && $ARGV[3] eq '--no-artwork' && $ARGV[4] eq '--now';
open my $calls, '>>', "$FindBin::Bin/calls" or die $!;
print {$calls} "x";
close $calls;
print '{"bundleIdentifier":"test.unsupported.player","padding":"', ('x' x 524288), '"}';
PERL
xcrun swiftc -parse-as-library -swift-version 5 -O -module-cache-path .build/swift-cache -target "$(uname -m)-apple-macosx13.0" \
  mac_app/UserAgent.swift mac_app/ConsoleOrder.swift mac_app/AppDisplayName.swift mac_app/ConsoleActions.swift \
  mac_app/LocalPairing.swift mac_app/NativeCore.swift mac_app/CodexCollector.swift mac_app/NativeMusic.swift \
  mac_app/NativeServer.swift tests/ServiceMemoryTests.swift -o "$contents/MacOS/MemoryTest"
"$contents/MacOS/MemoryTest"
