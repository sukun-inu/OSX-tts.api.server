# OSX-tts.api.server

Send it text, get back a recording of that text being read aloud.

macOS already knows how to read text out loud — that is the built-in `say` command. This
server puts it behind an HTTP API, so **a Windows machine or a browser can send text over
the network and receive an audio file** spoken by the Mac.

The intended setup is one Mac left running as the voice box. The eventual goal is to feed
a Discord bot that reads out comments, but what lives in this repository is the **API
server alone** — the bot integration is not implemented.

日本語版: [README.ja.md](README.ja.md)

## What it does

- Accepts text over HTTP and returns generated audio (WAV / M4A / MP3)
- Voice selection from the macOS voices, filterable by locale
- Generated files clean themselves up after delivery (5 s by default, 60 s TTL)
- Runs as a resident LaunchDaemon
- Caches repeat requests instead of regenerating them

## Requirements

- macOS with the `say` command (i.e. any normal install)
- Python 3.11+ (FastAPI, Uvicorn)
- `ffmpeg`, for MP3 output

## Setup

Production install and development startup are documented in
[README.ja.md](README.ja.md) (Japanese), which carries the exact commands.

## Documentation

| | |
|---|---|
| [docs/API.ja.md](docs/API.ja.md) | Endpoint list and worked examples |
| [docs/SPEC.md](docs/SPEC.md) | Detailed design and specification |
| [docs/ARCHITECTURE.ja.md](docs/ARCHITECTURE.ja.md) | Overall structure, config precedence, audio file lifecycle |
| [docs/STRUCTURE.ja.md](docs/STRUCTURE.ja.md) | Repository layout and post-install directory layout |
| [docs/CLIENTS.ja.md](docs/CLIENTS.ja.md) | Downloading audio from Windows and browsers |

Detailed documentation is Japanese-only, apart from `docs/SPEC.md`.
