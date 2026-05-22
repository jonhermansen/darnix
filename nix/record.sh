#!/usr/bin/env bash
set -euo pipefail

DURATION=${DURATION:-30}
OUTPUT=${1:-darnix-boot.cast}

DEMO_SCRIPT=$(mktemp)
trap "rm -f $DEMO_SCRIPT" EXIT

cat > "$DEMO_SCRIPT" << 'DEMO'
#!/usr/bin/env bash
set -euo pipefail

SERIAL_LOG="/tmp/darnix-serial.log"

printf '\n\033[1;32m$\033[0m '
for ((i=0; i<${#CMD}; i++)); do
  printf '%s' "${CMD:$i:1}"
  sleep 0.05
done
sleep 0.5
printf '\n\n'

rm -f "$SERIAL_LOG"
nix run .# 2>/dev/null &
qemu_pid=$!
trap "kill $qemu_pid 2>/dev/null; wait $qemu_pid 2>/dev/null" EXIT

sleep "$DURATION"
DEMO

chmod +x "$DEMO_SCRIPT"

echo "Recording to $OUTPUT (duration=${DURATION}s)"
echo "Pre-build first:  nix build .#esp"
echo ""

CMD="nix run github:jonhermansen/darnix" DURATION="$DURATION" asciinema rec \
  --command "$DEMO_SCRIPT" \
  --title "Darnix — Darwin system built with Nix" \
  --window-size 100x30 \
  "$OUTPUT"

echo ""
echo "Recorded: $OUTPUT"
echo "Play:     asciinema play $OUTPUT"
echo "Upload:   asciinema upload $OUTPUT"
