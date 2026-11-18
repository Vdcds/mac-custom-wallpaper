#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -parse-as-library Sources/Library.swift Sources/Repository.swift Tests/RepositoryTests.swift -o .build/repository-tests -framework AppKit -framework AVFoundation -framework CryptoKit
.build/repository-tests
