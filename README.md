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
- **Homebrew or MacPorts** — either one; used to install Python and ffmpeg
- Python 3.11+ (FastAPI, Uvicorn) — the installer adds it if missing
- `ffmpeg`, for MP3 output

Both package managers are supported. Which one is in use is recorded in
`/usr/local/opt/tts-api/.pkg-manager` and honoured from then on.

## Setup

Production install and development startup are documented in
[README.ja.md](README.ja.md) (Japanese), which carries the exact commands.

Pick a package manager explicitly with `--pkg-manager brew|macports|auto`
(default `auto`, also settable via `TTS_PKG_MANAGER`):

```bash
curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- \
  --pkg-manager macports
```

With `auto`, the recorded choice wins; failing that, whichever one is
installed. If **both** are installed and nothing is recorded, the installer
stops and asks you to pick — it never guesses.

## Switching package managers

Install the target manager first, then:

```bash
# see what would happen, change nothing
bash /usr/local/opt/tts-api/scripts/migrate-pkg-manager.sh --to macports --dry-run

# do it
bash /usr/local/opt/tts-api/scripts/migrate-pkg-manager.sh --to macports
```

It backs up `.env`, the plist and `.pkg-manager`, moves `.venv` aside
(never deletes it), rebuilds the virtualenv in place with the target
Python, rewrites `TTS_FFMPEG_PATH` when it pointed at the old manager,
restarts the daemon and health-checks it. Any failure rolls back
automatically and the server keeps running on the original manager.

The old manager and its packages are left installed — removing them is
your call.

> **Before uninstalling Homebrew**: the default install paths
> (`/usr/local/opt/tts-api`, `/usr/local/var/...`) sit inside the folders
> Homebrew uses on Intel Macs. Run Homebrew's own uninstaller in dry-run
> mode first and confirm tts-api is not in its deletion list, and back up
> `/usr/local/opt/tts-api/.env`:
>
> ```bash
> /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" -- --dry-run
> ```

## Documentation

| | |
|---|---|
| [docs/API.ja.md](docs/API.ja.md) | Endpoint list and worked examples |
| [docs/SPEC.md](docs/SPEC.md) | Detailed design and specification |
| [docs/ARCHITECTURE.ja.md](docs/ARCHITECTURE.ja.md) | Overall structure, config precedence, audio file lifecycle |
| [docs/STRUCTURE.ja.md](docs/STRUCTURE.ja.md) | Repository layout and post-install directory layout |
| [docs/CLIENTS.ja.md](docs/CLIENTS.ja.md) | Downloading audio from Windows and browsers |

Detailed documentation is Japanese-only, apart from `docs/SPEC.md`.
