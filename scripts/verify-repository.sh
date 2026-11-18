#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/test-repository.sh
./scripts/build.sh
RUN="$PWD/artifacts/repository-verification-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN/library"
if ! "$PWD/.build/Wake Scenes.app/Contents/MacOS/WakeScenes" --repository-self-test --library "$RUN/library" > "$RUN/run.log" 2>&1; then
    cat "$RUN/run.log"
    exit 1
fi
cat "$RUN/run.log"
test -f "$RUN/library/repository-verification.json"
echo "Report: $RUN/library/repository-verification.json"
