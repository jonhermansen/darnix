#!/usr/bin/env bash
set -euo pipefail

DWELL=${DWELL:-8}
OUTPUT=${1:-darnix-boot.cast}
SERIAL_LOG="/tmp/puredarwin-serial.log"

type_slow() {
  local text="$1" delay="${2:-0.05}"
  for ((i=0; i<${#text}; i++)); do
    printf '%s' "${text:$i:1}"
    sleep "$delay"
  done
}

run_demo() {
  printf '\n\033[1;32m$\033[0m '
  type_slow "nix run"
  sleep 0.5
  printf '\n\n'

  rm -f "$SERIAL_LOG"
  nix run .# 2>&1 &
  local qemu_pid=$!

  # Wait for the banner to appear in serial output, then dwell and exit clean
  while ! grep -q "Hello from Nix" "$SERIAL_LOG" 2>/dev/null; do
    sleep 0.2
    if ! kill -0 "$qemu_pid" 2>/dev/null; then break; fi
  done

  sleep "$DWELL"
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
}

echo "Recording to $OUTPUT (dwell=${DWELL}s after banner)"
echo "Pre-build first:  nix build .#esp"
echo ""

asciinema rec \
  --command "bash -c '$(declare -f type_slow); SERIAL_LOG=$SERIAL_LOG DWELL=$DWELL $(declare -f run_demo); run_demo'" \
  --title "Darnix — XNU booted from Nix" \
  --cols 100 --rows 40 \
  "$OUTPUT"

echo ""
echo "Recorded: $OUTPUT"
echo "Play:     asciinema play $OUTPUT"
echo "Upload:   asciinema upload $OUTPUT"
