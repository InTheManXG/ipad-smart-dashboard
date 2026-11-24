#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# 无图形会话的 CI 不能验证 GUI LaunchAgent，明确跳过而不伪造通过。
if [[ "$(uname -s)" != "Darwin" ]] || ! /bin/launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  echo "跳过后台生命周期测试：当前环境没有 macOS GUI launchd 域"
  exit 0
fi

mkdir -p .build
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path .build/swift-cache -target "$(uname -m)-apple-macosx13.0" \
  mac_app/UserAgent.swift mac_app/ConsoleOrder.swift mac_app/AppDisplayName.swift mac_app/ConsoleActions.swift mac_app/LocalPairing.swift mac_app/NativeCore.swift mac_app/CodexCollector.swift mac_app/NativeMusic.swift mac_app/NativeServer.swift tests/ServiceLifecycleTests.swift -o .build/service-lifecycle-tests
.build/service-lifecycle-tests
