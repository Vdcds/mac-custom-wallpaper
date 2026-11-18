#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -parse-as-library Sources/Wake.swift Tests/WakeGateTests.swift -o .build/wake-gate-tests -framework AppKit
.build/wake-gate-tests
