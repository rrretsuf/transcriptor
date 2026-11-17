#!/usr/bin/env python3
"""A stand-in for the Soniox real-time socket, for end-to-end tests without a key.

It speaks the same protocol: one JSON config, then 16 kHz s16le audio, then an
empty text frame. For every half second of audio that is louder than silence it
answers with one final token, "heard", so the transcript is proof that sound
travelled from the audio device to the socket. With diarization on, tokens
carry a speaker, as Soniox sends them.

    mock-soniox.py [port]   →   ws://127.0.0.1:<port>
"""
import array
import asyncio
import json
import math
import sys

import websockets

HALF_SECOND = 16000  # bytes: 8000 samples of s16le


async def session(socket, _path=None):
    config = json.loads(await socket.recv())
    speaker = {"speaker": "1"} if config.get("enable_speaker_diarization") else {}
    pending = b""
    async for frame in socket:
        if frame == "":
            await socket.send(json.dumps({"tokens": [], "finished": True}))
            return
        pending += frame
        while len(pending) >= HALF_SECOND:
            samples = array.array("h", pending[:HALF_SECOND])
            pending = pending[HALF_SECOND:]
            rms = math.sqrt(sum(s * s for s in samples) / len(samples)) / 32768
            if rms > 0.01:
                await socket.send(json.dumps({"tokens": [{"text": " heard", "is_final": True, **speaker}]}))


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    async with websockets.serve(session, "127.0.0.1", port):
        await asyncio.Future()


asyncio.run(main())
