#!/bin/bash
# Screenshots of every screen, for a person to look at after a CI run.
#   xvfb-run -a dbus-run-session -- ci/screens-linux.sh <transcriptor binary> <output folder>
set -uo pipefail
BIN=$(realpath "$1")
OUT=$2
HERE=$(dirname "$(realpath "$0")")
mkdir -p "$OUT"
pgrep -x openbox >/dev/null || { openbox & sleep 1; }
shot() { sleep "${2:-1.5}"; import -window root "$OUT/linux-$1.png"; }

export TRANSCRIPTOR_DATA_DIR=$(mktemp -d)
"$BIN" & sleep 5
shot onboarding 0
pkill -x transcriptor; sleep 1

echo '{"onboarded": true}' > "$TRANSCRIPTOR_DATA_DIR/config.json"
cp "$HERE/sample-history.json" "$TRANSCRIPTOR_DATA_DIR/history.json"
for theme in Adwaita Adwaita:dark; do
  name=${theme/Adwaita:/}; name=${name/Adwaita/light}
  GTK_THEME=$theme "$BIN" --show history & sleep 5
  shot "$name-history" 0
  for view in meeting file settings; do "$BIN" --show $view; shot "$name-$view"; done
  "$BIN" --toggle; shot "$name-pill" 1
  pkill -x transcriptor; sleep 1
done
ls -l "$OUT"
