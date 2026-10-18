# Integrating Kokoro TTS into an existing agent

This is a short implementation brief for a coding agent that needs to add
speech output to an existing Node/TypeScript agent.

The TTS service is **already installed and running**. Do not reimplement TTS,
do not install another model, and do not call the `kokoro-speak` CLI.

## What already exists

- Repository: <https://github.com/henksys/arch-kokoro>
- API base URL: `http://127.0.0.1:8880/v1`
- OpenAI-compatible endpoint: `POST /v1/audio/speech`
- Model name: `kokoro`
- Default voice: `af_sky`
- Authentication: none by default
- Network scope: loopback only, so the agent must run on the same machine
- Service check: `systemctl --user status kokoro-tts.service`
- Health check: `curl -s http://127.0.0.1:8880/health`

The service exposes PCM as raw 24 kHz, signed 16-bit, mono audio. That is the
lowest-latency format and the recommended integration path.

## Add the dependency

In the agent project:

```bash
npm install openai
```

The agent also needs `ffplay`, which is part of `ffmpeg` and is already
installed on Omarchy.

## Drop-in TypeScript module

Create `src/tts/kokoro.ts`:

```ts
import OpenAI from "openai";
import { spawn, type ChildProcess } from "node:child_process";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

export interface SpeakOptions {
  voice?: string;
  speed?: number;
}

export class KokoroTTS {
  private readonly client: OpenAI;
  private controller: AbortController | null = null;
  private player: ChildProcess | null = null;

  constructor() {
    this.client = new OpenAI({
      baseURL: process.env.KOKORO_BASE_URL ?? "http://127.0.0.1:8880/v1",
      apiKey: process.env.KOKORO_API_KEY || "not-needed",
    });
  }

  stop(): void {
    this.controller?.abort();
    this.player?.kill("SIGTERM");
    this.controller = null;
    this.player = null;
  }

  async speak(text: string, options: SpeakOptions = {}): Promise<void> {
    const clean = text.trim();
    if (!clean) return;

    // Starting a new utterance interrupts the previous one.
    this.stop();

    const controller = new AbortController();
    this.controller = controller;

    try {
      const response = await this.client.audio.speech.create(
        {
          model: "kokoro",
          voice: options.voice ?? process.env.KOKORO_VOICE ?? "af_sky",
          input: clean.slice(0, 4096),
          response_format: "pcm",
          stream_format: "audio",
          speed: options.speed ?? 1.0,
        },
        { signal: controller.signal },
      );

      if (!response.body) {
        throw new Error("Kokoro returned no audio body");
      }

      const player = spawn("ffplay", [
        "-nodisp",
        "-autoexit",
        "-loglevel", "error",
        "-f", "s16le",
        "-ar", "24000",
        "-ch_layout", "mono",
        "-",
      ]);

      this.player = player;

      const stdin = player.stdin;
      if (!stdin) {
        player.kill();
        throw new Error("Could not open ffplay stdin");
      }

      const source = Readable.fromWeb(response.body as never);

      const playerDone = new Promise<void>((resolve, reject) => {
        player.once("error", reject);
        player.once("close", (code) => {
          if (code === 0) resolve();
          else reject(new Error(`ffplay exited with code ${code}`));
        });
      });

      await Promise.all([pipeline(source, stdin), playerDone]);
    } catch (error) {
      // Aborts are expected during barge-in; do not surface them as failures.
      if (controller.signal.aborted) return;
      throw error;
    } finally {
      if (this.controller === controller) {
        this.controller = null;
        this.player = null;
      }
    }
  }
}
```

## Use it in the agent

```ts
import { KokoroTTS } from "./tts/kokoro.js";

const tts = new KokoroTTS();

await tts.speak("Hello, I am your local voice agent.", {
  voice: "af_sky",
  speed: 1.0,
});
```

Interrupt current speech:

```ts
tts.stop();
```

`speak()` automatically stops the previous utterance when called again.

## Raw API contract

If the agent uses plain HTTP instead of the OpenAI SDK:

```http
POST /v1/audio/speech
Content-Type: application/json
```

```json
{
  "model": "kokoro",
  "input": "Text to speak",
  "voice": "af_sky",
  "response_format": "pcm",
  "stream_format": "audio",
  "speed": 1.0
}
```

The response is raw audio:

- 24,000 Hz
- signed 16-bit little-endian
- mono

To play it directly with ffplay:

```bash
curl -sSN http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "kokoro",
    "input": "Hello from the agent.",
    "voice": "af_sky",
    "response_format": "pcm",
    "stream_format": "audio"
  }' \
  | ffplay -nodisp -autoexit -loglevel error \
      -f s16le -ar 24000 -ch_layout mono -
```

`mp3`, `wav`, `flac`, `opus`, and `aac` are also supported, but PCM is the best
choice for real-time speech.

## Barge-in and long text

- Use `response_format: "pcm"` and `stream_format: "audio"` for low latency.
- Call `tts.stop()` when the user interrupts or when a new response should
  replace the current one.
- The API accepts at most **4096 characters** per request.
- Split longer responses on sentence boundaries and speak them sequentially.
- Do not call `speak()` concurrently for a queue of sentences; `speak()` is
  designed to replace the current utterance. Use one sequential loop and a
  cancellation flag for barge-in.

Example sentence splitting:

```ts
const sentences = text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [text];

for (const sentence of sentences) {
  await tts.speak(sentence.trim());
}
```

## Test checklist

1. `curl -s http://127.0.0.1:8880/health` returns `"status":"ok"`.
2. `await tts.speak("Hello from the agent.")` produces audio.
3. `tts.stop()` silences a long utterance.
4. Starting a second `speak()` while the first is playing interrupts the first
   without an unhandled promise rejection.
5. Text longer than 4096 characters is split before calling the API.
6. The agent handles a missing `ffplay` and a stopped service without crashing.

## Do not

- Do not call `kokoro-speak` from Node; it is a CLI wrapper that writes
  temporary files.
- Do not use `response_format: "mp3"` for low-latency speech.
- Do not expose the Kokoro service to the LAN without adding an API key and
  firewall rules.
- Do not run the TTS model inside the agent process; it runs separately under
  systemd.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `KOKORO_BASE_URL` | `http://127.0.0.1:8880/v1` | API base URL, including `/v1`. |
| `KOKORO_API_KEY` | empty | Optional bearer token if the service requires one. |
| `KOKORO_VOICE` | `af_sky` | Default voice. |
