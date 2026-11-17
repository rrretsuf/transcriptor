#!/bin/bash
# Everything that can be checked on Linux without a person: run inside an X
# server and a session bus, for example
#   xvfb-run -a dbus-run-session -- ci/test-linux.sh <transcriptor binary>
# It builds a small desktop around the app: a window manager, a keyring and a
# PulseAudio server with a virtual speaker and a virtual microphone.
set -euo pipefail
BIN=$(realpath "$1")
HERE=$(dirname "$(realpath "$0")")
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-$(mktemp -d)}

pgrep -x openbox >/dev/null || { openbox & sleep 1; }
echo -n "test" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1 || true

if ! pactl info >/dev/null 2>&1; then
  pulseaudio --start --exit-idle-time=-1
  sleep 1
fi
if ! pactl list short sinks | grep -q micsink; then
  pactl load-module module-null-sink sink_name=speaker >/dev/null
  pactl load-module module-null-sink sink_name=micsink >/dev/null
  pactl load-module module-remap-source master=micsink.monitor source_name=mic >/dev/null
  pactl set-default-sink speaker
  pactl set-default-source mic
fi
# An idle null sink sleeps up to two seconds before a new recorder gets data;
# real hardware does not. A running low-latency recorder keeps it awake.
pgrep -x parec >/dev/null || { (parec -d mic --latency-msec=10 >/dev/null 2>&1 &); (parec -d speaker.monitor --latency-msec=10 >/dev/null 2>&1 &); sleep 2; }
espeak-ng -s 120 -w "$XDG_RUNTIME_DIR/count.wav" "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen"

echo "== self-test, with speech playing into the microphone"
(paplay --device=micsink "$XDG_RUNTIME_DIR/count.wav" &)
sleep 0.3
TRANSCRIPTOR_DATA_DIR=$(mktemp -d) TRANSCRIPTOR_EXPECT_AUDIO=mic "$BIN" --selftest
sleep 6

echo "== self-test, with speech playing on the speaker only"
(paplay --device=speaker "$XDG_RUNTIME_DIR/count.wav" &)
sleep 0.3
TRANSCRIPTOR_DATA_DIR=$(mktemp -d) TRANSCRIPTOR_EXPECT_AUDIO=system "$BIN" --selftest
sleep 6

echo "== hotkey and paste into another app"
"$HERE/e2e-linux.sh" "$BIN"

echo "== dictation from the microphone and a meeting from system audio, against a stand-in for Soniox"
python3 "$HERE/mock-soniox.py" 8765 &
MOCK=$!
sleep 1
SONIOX_API_KEY=mock TRANSCRIPTOR_SONIOX_URL=ws://127.0.0.1:8765 EXPECT=heard "$HERE/e2e-linux.sh" "$BIN"
kill $MOCK 2>/dev/null || true
