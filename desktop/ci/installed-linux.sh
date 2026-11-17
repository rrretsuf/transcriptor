#!/bin/bash
# The installers themselves: install the .deb, run the installed app, remove it,
# and the data folder must still be there. Then the AppImage must start as it is.
#   xvfb-run -a dbus-run-session -- ci/installed-linux.sh <folder with the installers>
set -euo pipefail
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/Transcriptor

# A keyring that was never opened asks for a password in a dialog and waits for a person.
echo -n "test" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1 || true

echo "== .deb"
sudo apt-get install -y "$(realpath "$1"/*.deb)" >/dev/null
timeout 180 transcriptor --selftest
test -f "$DATA/config.json"
sudo apt-get remove -y transcriptor >/dev/null
! command -v transcriptor >/dev/null
test -f "$DATA/config.json"
echo "ok   installed, ran, removed; $DATA is still there"

echo "== AppImage"
chmod +x "$1"/*.AppImage
APPIMAGE_EXTRACT_AND_RUN=1 timeout 180 "$1"/*.AppImage --selftest
echo "ok   the AppImage starts on its own"
