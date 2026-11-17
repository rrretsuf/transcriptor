#!/bin/bash
# End to end on a real X11 desktop: a text field in another app has the keyboard,
# the global hotkey is pressed, and the text must arrive in that field.
#   e2e-linux.sh <transcriptor binary>
# With SONIOX_API_KEY set and a PulseAudio sink named "micsink" feeding the
# default microphone, the text is a real dictation of synthetic speech, followed
# by a meeting that hears speech played on the default output "speaker".
set -euo pipefail
BIN=$1
export TRANSCRIPTOR_DATA_DIR=$(mktemp -d)
TYPED=$TRANSCRIPTOR_DATA_DIR/typed.txt

pgrep -x openbox >/dev/null || { openbox & sleep 1; }
zenity --entry --title=Target --text="Dictation target" > "$TYPED" &
xdotool search --sync --name '^Target$' windowactivate --sync

"$BIN" --selftest-e2e &
APP=$!
for _ in $(seq 100); do [ -f "$TRANSCRIPTOR_DATA_DIR/selftest-ready" ] && break; sleep 0.2; done
sleep 0.5
[ "$(xdotool getactivewindow getwindowname)" = "Target" ] || { echo "FAIL: launching Transcriptor took the keyboard"; exit 1; }

xdotool key ctrl+shift+space
if [ -n "${SONIOX_API_KEY:-}" ]; then
  sleep 1.5
  espeak-ng -s 140 -w "$TRANSCRIPTOR_DATA_DIR/speech.wav" "Hello, this is a test of the dictation."
  paplay --device=micsink "$TRANSCRIPTOR_DATA_DIR/speech.wav"
  sleep 0.8
  [ "$(xdotool getactivewindow getwindowname)" = "Target" ] || { echo "FAIL: the pill took the keyboard"; exit 1; }
  xdotool key ctrl+shift+space
  for _ in $(seq 300); do [ -f "$TRANSCRIPTOR_DATA_DIR/selftest-meeting" ] && break; sleep 0.2; done
  sleep 1
  espeak-ng -s 140 -w "$TRANSCRIPTOR_DATA_DIR/call.wav" "Good morning everyone, let us start the meeting."
  paplay --device=speaker "$TRANSCRIPTOR_DATA_DIR/call.wav"
  touch "$TRANSCRIPTOR_DATA_DIR/selftest-meeting-played"
fi
wait $APP && STATUS=0 || STATUS=$?
sleep 0.5
xdotool key Return
sleep 0.5

echo "typed into the other app: $(cat "$TYPED")"
[ "$STATUS" = 0 ] || { echo "FAIL: self-test exit $STATUS"; exit 1; }
grep -qiE "${EXPECT:-Hello from Transcriptor}" "$TYPED" || { echo "FAIL: the text did not arrive"; exit 1; }
echo "ok   hotkey → pill → paste into another app"
