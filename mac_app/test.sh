#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p .build
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path .build/swift-cache -target arm64-apple-macosx13.0 \
  mac_app/UserAgent.swift mac_app/ConsoleOrder.swift mac_app/AppDisplayName.swift mac_app/ConsoleActions.swift mac_app/LocalPairing.swift mac_app/NativeCore.swift mac_app/CodexCollector.swift mac_app/NativeMusic.swift mac_app/NativeServer.swift tests/NativeTests.swift -o .build/native-tests
.build/native-tests
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path .build/swift-cache -target arm64-apple-macosx13.0 \
  mac_app/SingleInstance.swift tests/SingleInstanceTests.swift -o .build/single-instance-tests
.build/single-instance-tests
