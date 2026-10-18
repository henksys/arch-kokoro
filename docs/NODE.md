# Using Kokoro TTS from Node / TypeScript

The local server implements OpenAI's `POST /v1/audio/speech` API, so the
official [`openai`](https://www.npmjs.com/package/openai) package works without
a custom client.

## Install the example dependencies

```bash
cd /path/to/arch-kokoro/examples/node
npm install
```

The examples use the pinned `openai` package from `package.json`.

## Buffered playback

The simplest pattern is to generate a complete MP3 and play it.

```ts
import OpenAI from "openai";
import { writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";

const client = new OpenAI({
  baseURL: "http://127.0.0.1:8880/v1",
  apiKey: "not-needed",
});

const response = await client.audio.speech.create({
  model: "kokoro",
  voice: "af_sky",
  input: "Hello from my agent.",
  response_format: "mp3",
});

const file = "/tmp/kokoro.mp3";
await writeFile(file, Buffer.from(await response.arrayBuffer()));

spawn("mpv", ["--no-video", "--really-quiet", file], {
  stdio: "inherit",
});
```

Run the included version:

```bash
npm run speak -- "Hello from my Node agent."
```

Environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `KOKORO_BASE_URL` | `http://127.0.0.1:8880/v1` | API base URL, including `/v1`. |
| `KOKORO_API_KEY` | empty | Optional bearer token if the server requires one. |
| `KOKORO_VOICE` | `af_sky` | Voice name. |
| `KOKORO_NO_PLAY` | unset | Set to `1` to save without playing. |

## Streaming PCM

For a voice agent, PCM streaming is the best choice: playback starts while
Kokoro is still generating later sentences, and playback can be interrupted.

```ts
import OpenAI from "openai";
import { spawn } from "node:child_process";
import { Readable } from "node:stream";

const client = new OpenAI({
  baseURL: "http://127.0.0.1:8880/v1",
  apiKey: "not-needed",
});

const response = await client.audio.speech.create({
  model: "kokoro",
  voice: "af_sky",
  input: "This is streamed while it is generated.",
  response_format: "pcm",
  stream_format: "audio",
});

if (!response.body) throw new Error("No audio body");

const player = spawn("ffplay", [
  "-nodisp",
  "-autoexit",
  "-loglevel", "error",
  "-f", "s16le",
  "-ar", "24000",
  "-ch_layout", "mono",
  "-",
]);

if (!player.stdin) throw new Error("No ffplay stdin");

Readable.fromWeb(response.body as never).pipe(player.stdin);
```

Run the included version:

```bash
npm run stream -- "This is streamed as it is generated."
```

For MP3 streaming, use `response_format: "mp3"` and remove the
`-f s16le -ar 24000 -ch_layout mono` flags from ffplay. PCM avoids MP3 encoding latency,
so it is the better choice for real-time agents.

## Barge-in / interruption

Use an `AbortController` to cancel the HTTP request and kill the player when the
user starts speaking:

```ts
const controller = new AbortController();

const response = await client.audio.speech.create(
  {
    model: "kokoro",
    voice: "af_sky",
    input: "A long response that the user may interrupt.",
    response_format: "pcm",
    stream_format: "audio",
  },
  { signal: controller.signal },
);

// Later, when the user interrupts:
controller.abort();
player.kill("SIGTERM");
```

The server stops generating when the HTTP connection closes.

## Reusable agent helper

A small wrapper keeps your agent code clean:

```ts
import OpenAI from "openai";
import { spawn } from "node:child_process";
import { Readable } from "node:stream";

const kokoro = new OpenAI({
  baseURL: process.env.KOKORO_BASE_URL ?? "http://127.0.0.1:8880/v1",
  apiKey: process.env.KOKORO_API_KEY || "not-needed",
});

export async function speak(
  text: string,
  options: { voice?: string; signal?: AbortSignal } = {},
): Promise<void> {
  const response = await kokoro.audio.speech.create(
    {
      model: "kokoro",
      voice: options.voice ?? "af_sky",
      input: text,
      response_format: "pcm",
      stream_format: "audio",
    },
    { signal: options.signal },
  );

  if (!response.body) throw new Error("Kokoro returned no audio");

  const player = spawn("ffplay", [
    "-nodisp",
    "-autoexit",
    "-loglevel", "error",
    "-f", "s16le",
    "-ar", "24000",
    "-ch_layout", "mono",
    "-",
  ]);

  if (!player.stdin) throw new Error("Could not open ffplay stdin");

  Readable.fromWeb(response.body as never).pipe(player.stdin);

  await new Promise<void>((resolve, reject) => {
    player.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffplay exited with ${code}`));
    });
    player.on("error", reject);
  });
}
```

Then:

```ts
await speak("Hello, I am your local voice agent.", { voice: "af_sky" });
```

## SSE events

If you want the OpenAI `speech.audio.delta` event format, request
`stream_format: "sse"` and parse the `text/event-stream` body:

```ts
const response = await fetch("http://127.0.0.1:8880/v1/audio/speech", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    ...(process.env.KOKORO_API_KEY
      ? { Authorization: `Bearer ${process.env.KOKORO_API_KEY}` }
      : {}),
  },
  body: JSON.stringify({
    model: "kokoro",
    voice: "af_sky",
    input: "Streaming with SSE.",
    response_format: "mp3",
    stream_format: "sse",
  }),
});

if (!response.body) throw new Error("No SSE body");

const reader = response.body.getReader();
const decoder = new TextDecoder();
let buffer = "";

for (;;) {
  const { value, done } = await reader.read();
  if (done) break;

  buffer += decoder.decode(value, { stream: true });
  const frames = buffer.split("\n\n");
  buffer = frames.pop() ?? "";

  for (const frame of frames) {
    const line = frame.split("\n").find((part) => part.startsWith("data: "));
    if (!line) continue;

    const event = JSON.parse(line.slice(6));
    if (event.type === "speech.audio.delta") {
      const chunk = Buffer.from(event.audio, "base64");
      // Feed chunk to your player or file writer here.
      console.log("audio chunk:", chunk.length, "bytes");
    } else if (event.type === "speech.audio.done") {
      console.log("finished", event.usage);
    }
  }
}
```

For `response_format: "pcm"`, the deltas contain raw PCM that can be played as
soon as each delta arrives. For compressed formats, the clip is encoded first
and then split into base64 deltas.

## Notes

- The base URL must include `/v1`.
- The SDK requires a non-empty `apiKey` value even when the server has no auth.
  Use `"not-needed"`.
- `voice` and `model` are typed as strings by the current Node SDK, so
  `af_sky` and `kokoro` compile without casts.
- The server accepts `input` up to 4096 characters, matching OpenAI. Split
  longer agent responses into sentences or paragraphs.
- Synthesis is serialized. If your agent fires overlapping requests, they queue.
  For barge-in, abort the previous request before starting the next.
- `instructions` is accepted but ignored; Kokoro has no instruction control.
