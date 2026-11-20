# Transcriptor for Windows and Linux

The same app as the Mac one in the repository root, for Windows 10/11 and
Linux (X11 and Wayland). A [Tauri 2](https://tauri.app) app: the core is Rust,
the windows are plain HTML, CSS and JavaScript with no build step.

It reads and writes the same `config.json` and `history.json` as the Mac app.

| | Windows | Linux |
| --- | --- | --- |
| Data | `%APPDATA%\Transcriptor` | `$XDG_DATA_HOME/Transcriptor` (`~/.local/share/Transcriptor`) |
| Soniox key | Credential Manager | Secret Service (GNOME Keyring, KWallet); a `0600` file if there is none |
| Hotkey | `RegisterHotKey` | X11 grab; on Wayland the GlobalShortcuts portal, or `transcriptor --toggle` bound in the desktop's settings |
| Paste | `SendInput` Ctrl+V | XTest Ctrl+V; on Wayland the RemoteDesktop portal, then `wtype`, then `ydotool` |
| System audio (meetings) | WASAPI loopback | the default sink's PulseAudio/PipeWire monitor |

`TRANSCRIPTOR_DATA_DIR` moves the data folder. Uninstalling never touches it.

## Layout

```
src-tauri/src
  main.rs      commands for the windows, startup, command line
  app.rs            dictation: hotkey → microphone → Soniox → paste → history
  meeting.rs        meeting: microphone + system audio, pause, continue, end
  meeting_detect.rs automatic meeting detection (WASAPI on Windows, PipeWire/PulseAudio + X11 on Linux)
  soniox.rs         the real-time socket protocol and one session
  files.rs     file transcription through the Soniox async API
  audio.rs     capture in shared mode, device changes, system audio mix
  dsp.rs       resampler to 16 kHz, 40 ms chunks, silence detector
  store.rs     config.json and history.json, atomic, never overwrites what it cannot read
  shell.rs     windows, the pill overlay, tray
  paste.rs  hotkey.rs  keystore.rs  linux.rs (portals)  selftest.rs
ui/            index.html (onboarding + app), pill.html (overlay)
ci/            what CI runs on real Windows and Linux machines
```

## Build and test

```bash
cd src-tauri
cargo test                              # unit tests, whole sessions against a local socket included
npx @tauri-apps/cli@2 dev               # run it
npx @tauri-apps/cli@2 build             # installers in target/release/bundle
```

Linux needs `libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libasound2-dev`.

Checks that need a desktop but no person (see `ci/`):

```bash
transcriptor --selftest        # storage, hotkey, key store, overlay, capture latency, TLS to Soniox
xvfb-run -a dbus-run-session -- ci/test-linux.sh target/release/transcriptor
pwsh ci/test-windows.ps1 target\release\transcriptor.exe
```

`test-linux.sh` builds a desktop with a virtual speaker and microphone, then
presses the real hotkey: a dictation must be pasted into another app's text
field, and a meeting must hear speech that only the speaker plays.

## Command line

```
transcriptor                  open the window (or bring the running one forward)
transcriptor --toggle         start or stop dictation in the running app
transcriptor --show settings  open on a view: history, meeting, file, settings
transcriptor --hidden         start in the tray (what launch at login uses)
```
