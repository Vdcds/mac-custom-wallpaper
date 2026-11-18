#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo 'Verification fixtures require ffmpeg (the app does not).'; exit 1; }
./scripts/build.sh
RUN="$PWD/artifacts/verification-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
# Original synthetic footage; source audio checks that the player is muted.
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=1280x720:rate=30:duration=4' -f lavfi -i 'sine=frequency=440:duration=8' -c:v libx264 -pix_fmt yuv420p -c:a aac "$RUN/Motion Test.mp4"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=360x640:rate=24:duration=4' -c:v hevc_videotoolbox -tag:v hvc1 -pix_fmt yuv420p "$RUN/Portrait HEVC.mov"
for CODEC in h264 hevc; do
    if [ "$CODEC" = h264 ]; then FIXTURE="$RUN/Motion Test.mp4"; else FIXTURE="$RUN/Portrait HEVC.mov"; fi
    if [ "$CODEC" = h264 ]; then SECOND="$RUN/Portrait HEVC.mov"; else SECOND="$RUN/Motion Test.mp4"; fi
    mkdir -p "$RUN/$CODEC"
    if ! "$PWD/.build/Wake Scenes.app/Contents/MacOS/WakeScenes" --self-test --library "$RUN/$CODEC/library" --fixture "$FIXTURE" --expected-duration 4 --second-fixture "$SECOND" > "$RUN/$CODEC/run.log" 2>&1; then
        cat "$RUN/$CODEC/run.log"
        exit 1
    fi
    cat "$RUN/$CODEC/run.log"
    test -f "$RUN/$CODEC/library/verification.json"
done
echo "Reports: $RUN/{h264,hevc}/library/verification.json"
