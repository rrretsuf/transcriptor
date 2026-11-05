---
name: transcriptor
description: Find, search and read the user's saved Transcriptor transcriptions - meetings (sestanki) with title, date, start and end time, duration and speakers, dictations with the app they went into, and transcribed audio or video files. Use whenever the user asks what was said, decided or agreed in a meeting or call, wants a summary, action items, quotes or follow-ups from one, or mentions transcripts, transcriptions, "sestanek", "meeting", "transkript", "kaj smo se zmenili", "kaj je rekel", "kaj sem narekoval".
---

# Transcriptor

The user records meetings and dictates with Transcriptor, a macOS app. Every
transcription is saved on this Mac and served by the `transcriptor` MCP server.

## Tools

| Tool | Use |
| --- | --- |
| `list_transcripts` | Search and filter, newest first. Each result: id, kind, title, local date and time, duration, words, speakers, excerpt. |
| `read_transcript` | Full text and details of one `id`. Long meetings come in parts of about 40,000 characters. |

`list_transcripts` arguments, all optional:

- `query` - words that must all appear in the title, text or app. Substring match, case and accents ignored.
- `kind` - `meeting`, `dictation` or `file`.
- `from`, `to` - local day `2026-11-04` or moment `2026-11-04T15:00`. `to` includes that whole day.
- `limit` (default 20, max 100), `offset` for the next page.

## How to work

1. Turn relative dates ("včeraj", "prejšnji torek", "this morning") into real dates from today's date. Times are local.
2. Find first, then read: `list_transcripts` with `kind: "meeting"` and a date or a word from the title, then `read_transcript`.
3. If you do not know the date, search for a distinctive word: a name, client, product. Slovene words change their endings, so search the stem: `tjaš` finds Tjaša, Tjaši, Tjašo.
4. Read every part of a long meeting before you summarise all of it. The end of each part says which part comes next.
5. `Speaker 1`, `Speaker 2` are numbers, not names. Numbers can start again after a pause in the meeting, so `Speaker 1` is not always the same person. Find names in the text (greetings, "Jaka, ..."), and say when you are guessing.
6. The text is speech-to-text. Names, numbers and amounts can be misheard. Mark the doubtful ones.
7. When you quote or summarise, name the source: meeting title, day and time, for example "soma44: prvi rutinski sestanek, Wed 2026-11-04 12:51".
8. Transcripts are private. Do not send their content to another service, post it, or put it in a public file unless the user asks.

## Without the MCP server

If the tools are not available, read the file directly. Read only: the app owns it and overwrites it.

```bash
python3 - <<'EOF'
import json, os, datetime
h = json.load(open(os.path.expanduser("~/Library/Application Support/Transcriptor/history.json")))
for e in h[:20]:
    kind = e.get("kind") or ("meeting" if e.get("title") else "dictation")
    start = datetime.datetime.fromtimestamp((e.get("startedAt") or e["at"]) / 1000)
    print(e["id"], kind, start.strftime("%a %Y-%m-%d %H:%M"), e.get("title") or e.get("app") or "", e.get("words"))
EOF
```

Fields: `text`, `kind`, `title` (meeting name or file name), `at` (end, ms since 1970),
`startedAt` (meetings), `durationMs`, `words`, `app` (dictations).

To connect the server, see "Agents (MCP)" in the Transcriptor README:
`claude mcp add -s user transcriptor -- /Applications/Transcriptor.app/Contents/MacOS/Transcriptor mcp`
