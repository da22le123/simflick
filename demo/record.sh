#!/bin/sh
# Records the simulator while simflick runs one goal. Output: demo/out/<name>/{sim.mov,run.json,meta.json,run.log}
# usage: demo/record.sh <name> "<goal>" [extra simflick run flags]
set -e
cd "$(dirname "$0")"
NAME=$1; GOAL=$2; shift 2
UDID=${UDID:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}
OUT=out/$NAME; mkdir -p "$OUT"; rm -f "$OUT"/*
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/sim.mov" 2> "$OUT/rec.log" &
REC=$!
until grep -q "Recording started" "$OUT/rec.log" 2>/dev/null; do sleep 0.05; done
REC_AT=$(node -e 'console.log(Date.now())')
sleep 1  # a beat of the start screen before the agent moves
simflick run "$GOAL" --shot "$@" | tee "$OUT/run.log" || true
sleep 1.5  # and a beat of the result
kill -INT $REC; wait $REC 2>/dev/null || true
cp "$(ls -t ~/.simflick/runs/*.json | head -1)" "$OUT/run.json"
echo "{\"recordingStartedAt\": $REC_AT, \"goal\": $(node -e 'console.log(JSON.stringify(process.argv[1]))' "$GOAL")}" > "$OUT/meta.json"
echo "recorded $OUT"
