# Transcriber

Press a hotkey anywhere on macOS, speak, and the text lands at your cursor.
Streaming speech-to-text through the [Soniox](https://soniox.com) real-time API.

- Menu bar app — no dock icon, no window in the way.
- One glass surface that stays out of your way: a small capsule while you talk,
  clicked open into a live transcript you can drag taller.
- Dock it at the bottom, the left edge or the right edge.
- Pastes straight into whatever app you were typing in.
- Every transcription is kept locally and searchable.
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

`dist/mac-arm64/Transcriber.app` is signed with your local **Transcriber Local Signing**
identity. Drag it to `/Applications`. Because the identity (not the build hash) is what
macOS ties the Accessibility grant to, the grant survives future rebuilds — grant it once.

## Use

| Action | Key |
| --- | --- |
| Start / stop dictation | `⌘⇧Space` |
| Dictate an email | `⌘⇧E` |
| Cancel without pasting | `Esc` |
| Show or hide the live transcript | Click the capsule |
| Resize the transcript | Drag its grip |

The menu bar icon animates while recording, and its menu holds
**All transcriptions**, **Copy last transcription** and **Settings**.

## Settings

- **Usage** — requests, audio minutes and spend pulled from Soniox, next to your
  own local counts.
- **Model** — defaults to `stt-rt-v5`, Soniox's current real-time model.
- **Languages** — hints for the recognizer. Add none for auto-detection.
- **Translate to** — transcribe in one language, paste in another.
- **Vocabulary** — names and jargon Soniox should get right.
- **Position** — where the capsule sits.
- **Stop after silence** — finish automatically instead of pressing the hotkey again.
- **Keep transcriptions** — local history on or off.
- **After-transcript cleanup** — optional polish through OpenRouter
  (`thinkingmachines/inkling-small` on Baseten) before pasting.
  Off by default; Light removes filler words, Medium adds punctuation and
  paragraphs, Hard structures the text for reuse as AI instructions.
  Model and provider are configurable, with Verify buttons.
- **Email dictation** — `⌘⇧E` structures the transcript as an email in your
  writing style (learned from sent mail). On by default, with its own
  OpenRouter model and provider.

## How it works

```
hotkey → getUserMedia → AudioWorklet (16 kHz s16le, 40 ms chunks)
       → wss://stt-rt.soniox.com/transcribe-websocket
       → final + partial tokens → surface
       → clipboard → ⌘V at the cursor
```

Audio is streamed as it is spoken, so most of the transcript is already final by
the time you stop talking. Audio itself is never written to disk.

Local state lives in `~/Library/Application Support/Transcriber`:
`config.json` (key encrypted) and `history.json`.

## License

MIT
