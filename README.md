# arch-kokoro

**Lean CPU-only Kokoro TTS install script for Arch Linux / Omarchy, running at user level with
a systemd user service.**

A small, local text-to-speech service based on
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) and
[kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx).

Repository: <https://github.com/henksys/arch-kokoro>

The service is deliberately lean:

- ONNX Runtime, not PyTorch
- Int8 model by default (114 MB instead of 326 MB)
- No CUDA/NVIDIA components
- No Docker
- No web UI
- No speech-to-text stack
- Listens on `127.0.0.1:8880` only
- Runs as a `systemd --user` service

It exposes an OpenAI-compatible `POST /v1/audio/speech` endpoint, so your Node
agent can use the official `openai` package with only a changed base URL.

## What gets installed

| Item | Location |
| --- | --- |
| Project files | this checkout (for example `~/Projects/arch-kokoro`) |
| Virtual environment | `~/.local/share/kokoro-tts/venv` |
| Model and voices | `~/.local/share/kokoro-tts/models` |
| Configuration | `~/.config/kokoro-tts/env` |
| systemd unit | `~/.config/systemd/user/kokoro-tts.service` |
| uv binary | `~/.local/bin/uv` (if uv was not already installed) |

The installer does **not** install system packages. Omarchy already provides
`ffmpeg`, `ffprobe`, `curl`, and `jq`. If one is missing, the installer stops
and tells you which package to install.

### Measured footprint on a testing machine

- Python virtual environment: about 162 MB
- Int8 model + 54 voices: about 136 MB
- Service memory: about 280 MB idle, up to roughly 400 MB after sustained use
- Startup time: about 1.2 seconds

The uv cache and managed Python add roughly another 150 MB outside the runtime
directory. They make reinstalling and updating faster, so they are left in
place.

## Install

Clone the repository to a permanent location:

```bash
git clone https://github.com/henksys/arch-kokoro.git ~/Projects/arch-kokoro
cd ~/Projects/arch-kokoro
./install.sh
```

If you downloaded a ZIP archive instead, extract it first and run
`bash install.sh` if the executable bit was lost.

Use a permanent path. The generated systemd unit stores the absolute project
path, so if you move or delete the checkout later, rerun `./install.sh` from
the new location.

The first install needs internet access to download uv, Python, the pinned
packages, and the model. After that, the service runs fully offline.

The installer:

1. Checks that this is Omarchy/Arch and a supported CPU architecture.
2. Installs a pinned `uv` into `~/.local/bin` when needed.
3. Installs a managed Python 3.13.
4. Creates the virtual environment and installs the pinned Python packages.
5. Downloads the int8 model and the 54-voice pack, verifying SHA256 checksums.
6. Writes the configuration file.
7. Installs and starts `kokoro-tts.service` as a user service.
8. Tries to enable linger so the service starts at boot.
9. Runs a real `af_sky` synthesis test.

The only step that may require your password is enabling linger. If the
installer cannot do it, run:

```bash
sudo loginctl enable-linger "$USER"
```

To use the fp32 model instead of int8:

```bash
MODEL_VARIANT=fp32 ./install.sh
```

You can switch back with:

```bash
MODEL_VARIANT=int8 ./install.sh
```

Both models can stay on disk; only the one in the config is loaded.

### Installing on the other Omarchy machines

Copy this whole directory to `~/Projects/arch-kokoro` on each machine (or clone
it from GitHub), then run `./install.sh` from that directory. The installer
uses `$HOME`, the current user's systemd instance, and a pinned Python, so it
does not depend on the username or hostname.

The directory can be copied without `examples/node/node_modules`; run
`npm install` in `examples/node` only if you want to run the Node examples on
that machine.

## Verify

Check the service:

```bash
systemctl --user status kokoro-tts.service
```

Check the API:

```bash
curl -s http://127.0.0.1:8880/health | jq
```

List the available voices:

```bash
curl -s http://127.0.0.1:8880/v1/audio/voices | jq '.voices | length'
```

Generate and play a sentence, from the project directory:

```bash
./bin/kokoro-speak "Hello from Kokoro on Omarchy."
```

Save a file instead:

```bash
./bin/kokoro-speak --format wav --output /tmp/kokoro.wav --no-play "Saved to a file."
```

Run the quick smoke test:

```bash
./test.sh --quick
```

Run the full test suite (all formats, speeds, streaming, and error handling):

```bash
./test.sh
```

The full suite decodes the compressed/container formats with `ffmpeg`, checks
the raw PCM size, tests `stream_format=audio` and `stream_format=sse`, and
verifies the OpenAI-shaped error response.

## Service management

```bash
# Show status
systemctl --user status kokoro-tts.service

# Follow logs
journalctl --user -u kokoro-tts.service -f

# Restart after editing the config
systemctl --user restart kokoro-tts.service

# Stop / start
systemctl --user stop kokoro-tts.service
systemctl --user start kokoro-tts.service

# Disable at login
systemctl --user disable kokoro-tts.service
```

## Configuration

Edit `~/.config/kokoro-tts/env`, then restart the service.

| Variable | Default | Meaning |
| --- | --- | --- |
| `KOKORO_HOST` | `127.0.0.1` | Bind address. Keep loopback unless you understand the firewall implications. |
| `KOKORO_PORT` | `8880` | API port. |
| `KOKORO_DEFAULT_VOICE` | `af_sky` | Default voice used by `kokoro-speak` and by requests that omit a voice. |
| `KOKORO_MODEL_PATH` | int8 model | Absolute path to the ONNX model. |
| `KOKORO_VOICES_PATH` | voices file | Absolute path to `voices-v1.0.bin`. |
| `KOKORO_THREADS` | `4` | ONNX Runtime CPU threads. Lower uses less CPU; higher may reduce latency. |
| `KOKORO_API_KEY` | empty | When set, all `/v1` routes require `Authorization: Bearer <key>`. |
| `KOKORO_CORS_ORIGINS` | empty | Comma-separated browser origins, or `*`. Not needed for a Node backend. |
| `KOKORO_LOG_LEVEL` | `info` | `debug`, `info`, `warning`, or `error`. |

The default is loopback-only. If you later want LAN access, change
`KOKORO_HOST` to `0.0.0.0`, open the port in UFW for your LAN only, and set an
API key. Do not expose it to the public internet without a TLS reverse proxy.

## API

The API base URL is:

```text
http://127.0.0.1:8880/v1
```

Interactive OpenAPI documentation is available at:

```text
http://127.0.0.1:8880/docs
```

Minimal request:

```bash
curl -sS http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "kokoro",
    "input": "Hello from my agent.",
    "voice": "af_sky",
    "response_format": "mp3"
  }' \
  --output /tmp/hello.mp3
```

Play it:

```bash
mpv --no-video /tmp/hello.mp3
```

See [docs/API.md](docs/API.md) for the full endpoint reference, all response
formats, speed handling, streaming, SSE events, errors, and voice mappings.

## Node / TypeScript agent

The official OpenAI Node SDK works because the server implements the OpenAI
speech endpoint:

```ts
import OpenAI from "openai";
import { writeFile } from "node:fs/promises";

const client = new OpenAI({
  baseURL: "http://127.0.0.1:8880/v1",
  apiKey: "not-needed",
});

const response = await client.audio.speech.create({
  model: "kokoro",
  voice: "af_sky",
  input: "Hello from my Node agent.",
  response_format: "mp3",
});

await writeFile("/tmp/kokoro.mp3", Buffer.from(await response.arrayBuffer()));
```

For buffered playback, streaming PCM, and barge-in examples, see
[docs/NODE.md](docs/NODE.md) and the files in
[examples/node/](examples/node/).

If another coding agent is going to add speech to an existing project, give it
[docs/AGENT.md](docs/AGENT.md). It contains a dependency-free, ready-to-paste
`.mjs` module, the raw API contract, barge-in guidance, and a test checklist.

To run the included examples:

```bash
cd examples/node
npm install
npm run speak -- "Hello from my Node agent."
npm run stream -- "This is streamed as it is generated."
```

## Voices

Kokoro ships 54 voices. `af_sky` is the default in this setup. Other commonly
used voices are `af_heart`, `af_bella`, `am_michael`, and `bf_emma`.

```bash
curl -s http://127.0.0.1:8880/v1/audio/voices \
  | jq -r '.voices[] | [.id, .language, .gender] | @tsv'
```

Kokoro has no Dutch voices. The included languages are American English,
British English, Japanese, Mandarin Chinese, Spanish, French, Hindi, Italian,
and Brazilian Portuguese. The service is optimized for English usage; other
languages are passed through espeak-ng G2P and may be less accurate than
Kokoro-FastAPI's language-specific pipelines.

## Update

```bash
./update.sh
```

This reruns the installer. It updates Python packages only when
`server/requirements.txt` changes, verifies the model checksum, and restarts the
service.

## Uninstall

```bash
./uninstall.sh
```

This stops and removes the user service but keeps the model, virtual
environment, and configuration. To delete those as well:

```bash
./uninstall.sh --purge
```

Add `--yes` to skip the confirmation prompt.

Linger is a shared user setting and is not disabled automatically. To disable
it:

```bash
sudo loginctl disable-linger "$USER"
```

## Troubleshooting

### The service does not start

```bash
systemctl --user status kokoro-tts.service
journalctl --user -u kokoro-tts.service -n 100 --no-pager
```

### Port 8880 is already in use

The installer refuses to overwrite another service. Edit
`~/.config/kokoro-tts/env`, change `KOKORO_PORT`, and restart:

```bash
systemctl --user restart kokoro-tts.service
```

Then use the new port in the base URL.

### `ffmpeg` is missing

Install it:

```bash
sudo pacman -S ffmpeg
```

### The service works now but not after reboot

Check linger:

```bash
loginctl show-user "$USER" -p Linger
```

If it says `Linger=no`, run:

```bash
sudo loginctl enable-linger "$USER"
```

### API returns 401

An API key is configured. Include it:

```bash
-H "Authorization: Bearer <KOKORO_API_KEY>"
```

Or clear `KOKORO_API_KEY` in the config and restart.

### Node SDK cannot connect

The base URL must include `/v1`:

```ts
baseURL: "http://127.0.0.1:8880/v1"
```

The SDK also requires a non-empty `apiKey` value even when the server does not
require one. Use `"not-needed"`.

### Audio is generated but nothing plays

The CLI prefers `mpv`, then `ffplay`. Check that one is installed:

```bash
command -v mpv
command -v ffplay
```

If you are running the agent as a systemd user service, make sure it has access
to the desktop audio session (`XDG_RUNTIME_DIR` and PipeWire). Running the agent
in your normal desktop session avoids this issue.

## Design notes

- The server serializes synthesis with one asyncio lock. This keeps CPU use
  predictable and avoids loading multiple model copies. Concurrent requests
  wait in the HTTP queue.
- `stream_format=audio` with `response_format=pcm` is the lowest-latency path.
  Compressed formats are encoded as a complete clip and then sent in chunks.
- `stream_format=sse` emits `speech.audio.delta` events with base64 audio and a
  final `speech.audio.done` event.
- Speeds outside Kokoro's native `0.5–2.0` range are time-stretched with
  ffmpeg's `atempo`, so the OpenAI `0.25–4.0` range is accepted.
- `instructions` is accepted for compatibility but ignored; Kokoro has no
  instruction-following control.
- On a 16-core machine with four ONNX threads, a 3.2-second utterance took
  about 1.4 seconds of wall time. Raise `KOKORO_THREADS` for lower latency or
  lower it to leave more CPU for the rest of your agent.

## Licenses

- Kokoro-82M model weights: Apache 2.0
- `kokoro-onnx`: MIT
- This project's scripts and server code: MIT
