# Soniox Flow

Press a hotkey anywhere on macOS, speak, and the text lands at your cursor.
Streaming speech-to-text through the [Soniox](https://soniox.com) real-time API.

- Menu bar app — no dock icon, no window in the way.
- Global hotkey, floating pill with a live waveform and live transcript.
- Pastes straight into whatever app you were typing in.
- Your API key is encrypted in the macOS Keychain. Audio goes to Soniox and nowhere else.
- No account, no telemetry, no local model downloads.

## Requirements

- macOS on Apple Silicon
- Node.js 22+
- A Soniox API key from [console.soniox.com](https://console.soniox.com)

## Run

```bash
npm install
npm start
```

Add your API key in Settings, then grant **Microphone** and **Accessibility**
(Accessibility is what allows the paste at your cursor).

## Build a real app

```bash
npm run dist
```

The signed-for-local-use `.app` and `.dmg` land in `dist/`.

## Use

| Action | Key |
| --- | --- |
| Start / stop dictation | `⌘⇧Space` (configurable) |
| Cancel without pasting | `Esc` |

The menu bar icon animates while recording. `Copy last transcript` is in its menu.

## Settings

- **Model** — defaults to `stt-rt-v5`, Soniox's current real-time model.
- **Languages** — hints for the recognizer. Leave all off for auto-detection.
- **Translate to** — transcribe in one language, paste in another.
- **Vocabulary** — names and jargon Soniox should get right.
- **Stop after silence** — finish automatically instead of pressing the hotkey again.
- **Paste at cursor / Restore clipboard** — how the transcript reaches your app.

## How it works

```
hotkey → getUserMedia → AudioWorklet (16 kHz s16le, 40 ms chunks)
       → wss://stt-rt.soniox.com/transcribe-websocket
       → final + partial tokens → pill
       → clipboard → ⌘V at the cursor
```

Audio is streamed as it is spoken, so most of the transcript is already final by
the time you stop talking. Nothing is written to disk.

## License

MIT
