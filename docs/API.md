# Kokoro TTS API

Base URL:

```text
http://127.0.0.1:8880/v1
```

The speech endpoint follows OpenAI's `POST /v1/audio/speech` contract. The
official OpenAI SDKs work when you change the base URL and pass any non-empty
API key (the server ignores it unless `KOKORO_API_KEY` is configured).

## Authentication

Authentication is disabled by default because the server listens on loopback
only.

If `KOKORO_API_KEY` is set in `~/.config/kokoro-tts/env`, all `/v1` routes
require:

```http
Authorization: Bearer <KOKORO_API_KEY>
```

`GET /health` remains public for service checks.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/audio/speech` | Generate speech |
| `GET` | `/v1/audio/voices` | List all 54 voices |
| `GET` | `/v1/models` | OpenAI-style model list |
| `GET` | `/health` | Health and model information |

## `POST /v1/audio/speech`

### Request body

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `model` | string | yes | — | `kokoro`, `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts`, or `gpt-4o-mini-tts-2025-12-15`. |
| `input` | string | yes | — | 1–4096 characters. |
| `voice` | string or object | yes | — | A Kokoro voice such as `af_sky`, or `{"id": "af_sky"}`. OpenAI voice names are mapped as a fallback. |
| `response_format` | string | no | `mp3` | `mp3`, `opus`, `aac`, `flac`, `wav`, or `pcm`. |
| `speed` | number | no | `1.0` | `0.25`–`4.0`. Values outside Kokoro's native `0.5`–`2.0` range are time-stretched with ffmpeg. |
| `stream_format` | string | no | `audio` | `audio` or `sse`. |
| `instructions` | string | no | — | Accepted for compatibility, ignored because Kokoro has no instruction-following control. |

Unknown fields are ignored so newer SDKs do not break.

### Response formats

| `response_format` | Content type | Notes |
| --- | --- | --- |
| `mp3` | `audio/mpeg` | 128 kbps MP3 |
| `opus` | `audio/ogg` | Ogg Opus |
| `aac` | `audio/aac` | ADTS AAC |
| `flac` | `audio/flac` | FLAC |
| `wav` | `audio/wav` | 24 kHz, 16-bit mono PCM in a WAV container |
| `pcm` | `audio/pcm` | Raw 24 kHz, 16-bit little-endian mono PCM |

### Voice names

Use a native Kokoro name for exact control:

```text
af_sky
af_heart
af_bella
am_michael
bf_emma
```

List every voice:

```bash
curl -s http://127.0.0.1:8880/v1/audio/voices | jq
```

The response contains one object per voice:

```json
{
  "voices": [
    {
      "id": "af_sky",
      "name": "af_sky",
      "language": "en-us",
      "gender": "female"
    }
  ]
}
```

OpenAI's standard names are mapped as a convenience:

| OpenAI name | Kokoro voice |
| --- | --- |
| `alloy` | `af_alloy` |
| `ash` | `am_adam` |
| `ballad` | `bm_george` |
| `coral` | `af_heart` |
| `echo` | `am_echo` |
| `fable` | `bm_fable` |
| `onyx` | `am_onyx` |
| `nova` | `af_nova` |
| `sage` | `af_sarah` |
| `shimmer` | `af_sky` |
| `verse` | `am_michael` |
| `marin` | `af_heart` |
| `cedar` | `am_michael` |

Native Kokoro names always take priority if a name exists in both sets.

## Examples

### MP3 with curl

```bash
curl -sS http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "kokoro",
    "input": "Hello from my local agent.",
    "voice": "af_sky",
    "response_format": "mp3",
    "speed": 1.0
  }' \
  --output /tmp/hello.mp3
```

Play it:

```bash
mpv --no-video /tmp/hello.mp3
```

### WAV with an OpenAI model alias

```bash
curl -sS http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "tts-1",
    "input": "This uses an OpenAI model alias.",
    "voice": "af_sky",
    "response_format": "wav"
  }' \
  --output /tmp/hello.wav
```

### Voice object

```bash
curl -sS http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "kokoro",
    "input": "The voice can also be an object.",
    "voice": {"id": "af_sky"},
    "response_format": "mp3"
  }' \
  --output /tmp/hello.mp3
```

### Slow speech

```bash
curl -sS http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "kokoro",
    "input": "This is slower.",
    "voice": "af_sky",
    "response_format": "mp3",
    "speed": 0.75
  }' \
  --output /tmp/slow.mp3
```

`0.25` and `4.0` are also accepted. Extreme values use ffmpeg time-stretching
after Kokoro synthesis.

### PCM stream with curl

PCM is the lowest-latency path. Play it directly with ffplay:

```bash
curl -sS http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "kokoro",
    "input": "This audio is streamed while it is generated.",
    "voice": "af_sky",
    "response_format": "pcm",
    "stream_format": "audio"
  }' \
  | ffplay -nodisp -autoexit -loglevel error \
      -f s16le -ar 24000 -ch_layout mono -
```

### SSE stream

Set `stream_format` to `sse` to receive OpenAI speech events:

```bash
curl -sN http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "kokoro",
    "input": "Streaming over server-sent events.",
    "voice": "af_sky",
    "response_format": "mp3",
    "stream_format": "sse"
  }'
```

The response is `text/event-stream` with frames like:

```text
data: {"type":"speech.audio.delta","audio":"<base64 audio>"}

data: {"type":"speech.audio.done","usage":{"input_tokens":12,"output_tokens":0,"total_tokens":12}}
```

Decode each `audio` field and concatenate the bytes to reconstruct the requested
format.

For `response_format=pcm`, deltas are produced while Kokoro is synthesizing.
For compressed formats, the complete clip is encoded first and then split into
base64 deltas.

## Errors

Errors use OpenAI's JSON shape:

```json
{
  "error": {
    "message": "Voice 'not_a_real_voice' is not supported. Use a Kokoro voice such as af_sky.",
    "type": "invalid_request_error",
    "param": "voice",
    "code": "voice_not_found"
  }
}
```

Common status codes:

| Status | Meaning |
| --- | --- |
| `400` | Invalid model, voice, input, speed, or response format |
| `401` | Missing or incorrect bearer token |
| `500` | ffmpeg or speech-generation failure |
| `503` | Model still starting (health endpoint only) |

## Concurrency

The server uses one model instance and serializes synthesis with a lock. A
second request waits until the first one finishes. This is intentional for a
local single-user setup: it keeps CPU usage predictable and avoids duplicating
the model in memory.

For a multi-user or high-throughput deployment, run multiple service instances
on different ports or add a queue in front of the API.

## OpenAI SDK compatibility

Python:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8880/v1",
    api_key="not-needed",
)

audio = client.audio.speech.create(
    model="kokoro",
    voice="af_sky",
    input="Hello from Python.",
    response_format="mp3",
)

audio.write_to_file("/tmp/kokoro.mp3")
```

Node/TypeScript:

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
  input: "Hello from Node.",
  response_format: "mp3",
});

await writeFile("/tmp/kokoro.mp3", Buffer.from(await response.arrayBuffer()));
```

See [NODE.md](NODE.md) for streaming and barge-in examples.
