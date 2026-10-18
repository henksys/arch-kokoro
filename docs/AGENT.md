# Integrating Kokoro TTS into an existing Node.js agent

This is a short implementation brief for a coding agent that needs to add
speech output to an existing **JavaScript** project running on Node.js.

The TTS service is **already installed and running**. Do not reimplement TTS,
do not install another model, and do not call the `kokoro-speak` CLI.

The primary example has **no npm dependencies**. It uses Node's built-in
`fetch`, streams, child processes, and the existing `ffplay` binary.

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

## Module format: `.mjs`

The example below uses ES modules and is intended to be saved as `kokoro.mjs`.

- `.mjs` is always an ES module, regardless of `package.json`.
- Use `import` / `export`, not `require` / `module.exports`.
- Import the local module **with its extension**:

```js
import { KokoroTTS } from "./tts/kokoro.mjs";
```

- Top-level `await` is allowed in `.mjs`.
- If the project uses `.js` files instead, the same code works when
  `package.json` contains `"type": "module"`.

## Drop-in `.mjs` module

Create `src/tts/kokoro.mjs`:

```js
import { spawn } from "node:child_process";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

/**
 * @typedef {Object} SpeakOptions
 * @property {string} [voice]
 * @property {number} [speed]
 */

export class KokoroTTS {
  constructor() {
    this.baseUrl =
      process.env.KOKORO_BASE_URL ?? "http://127.0.0.1:8880/v1";
    this.apiKey = process.env.KOKORO_API_KEY || "";
    this.controller = null;
    this.player = null;
  }

  stop() {
    this.controller?.abort();
    this.player?.kill("SIGTERM");
    this.controller = null;
    this.player = null;
  }

  /**
   * @param {string} text
   * @param {SpeakOptions} [options]
   * @returns {Promise<void>}
   */
  async speak(text, options = {}) {
    const clean = text.trim();
    if (!clean) return;

    // Starting a new utterance interrupts the previous one.
    this.stop();

    const controller = new AbortController();
    this.controller = controller;

    try {
      const headers = { "Content-Type": "application/json" };
      if (this.apiKey) {
        headers.Authorization = `Bearer ${this.apiKey}`;
      }

      const response = await fetch(`${this.baseUrl}/audio/speech`, {
        method: "POST",
        headers,
        body: JSON.stringify({
          model: "kokoro",
          input: clean.slice(0, 4096),
          voice: options.voice ?? process.env.KOKORO_VOICE ?? "af_sky",
          response_format: "pcm",
          stream_format: "audio",
          speed: options.speed ?? 1.0,
        }),
        signal: controller.signal,
      });

      if (!response.ok) {
        throw new Error(
          `Kokoro API ${response.status}: ${await response.text()}`,
        );
      }

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

      const source = Readable.fromWeb(response.body);

      const playerDone = new Promise((resolve, reject) => {
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

```js
import { KokoroTTS } from "./tts/kokoro.mjs";

const tts = new KokoroTTS();

await tts.speak("Hello, I am your local voice agent.", {
  voice: "af_sky",
  speed: 1.0,
});
```

Interrupt current speech:

```js
tts.stop();
```

`speak()` automatically stops the previous utterance when called again.

## No npm dependencies

The module above needs no `npm install`. It uses only Node built-ins:

- `fetch`
- `AbortController`
- `node:child_process`
- `node:stream`
- `node:stream/promises`

The only non-Node runtime piece is `ffplay`, which is already installed as part
of `ffmpeg` on Omarchy. Node itself has no built-in speaker API, so playing audio
requires a player process, a browser/Electron audio API, or an npm audio package.

## Optional: OpenAI SDK instead of fetch

If the project already has the `openai` package, the SDK can be used instead of
the raw `fetch` call:

```bash
npm install openai
```

```js
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: process.env.KOKORO_BASE_URL ?? "http://127.0.0.1:8880/v1",
  apiKey: process.env.KOKORO_API_KEY || "not-needed",
});

const response = await client.audio.speech.create(
  {
    model: "kokoro",
    input: clean,
    voice: options.voice ?? "af_sky",
    response_format: "pcm",
    stream_format: "audio",
    speed: options.speed ?? 1.0,
  },
  { signal: controller.signal },
);
```

Everything after that — checking `response.body`, piping to `ffplay`, barge-in,
and cleanup — is identical.

## Raw API contract

If the agent uses plain HTTP instead of the module above:

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

```js
const sentences = text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [text];

for (const sentence of sentences) {
  await tts.speak(sentence.trim());
}
```

## Test checklist

1. `curl -s http://127.0.0.1:8880/health` returns `"status":"ok"`.
2. `node --check src/tts/kokoro.mjs` passes.
3. `await tts.speak("Hello from the agent.")` produces audio.
4. `tts.stop()` silences a long utterance.
5. Starting a second `speak()` while the first is playing interrupts the first
   without an unhandled promise rejection.
6. Text longer than 4096 characters is split before calling the API.
7. The agent handles a missing `ffplay` and a stopped service without crashing.

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
