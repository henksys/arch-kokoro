// Stream PCM audio from Kokoro to ffplay while it is being generated.
//
// Run from this directory:
//   npm install
//   npm run stream -- "This sentence is streamed as it is generated."
//
// The PCM path avoids MP3 encoding latency and is the best choice for a voice
// agent that may need to interrupt playback.
//
// Environment variables:
//   KOKORO_BASE_URL   API base URL, default http://127.0.0.1:8880/v1
//   KOKORO_API_KEY    Optional bearer token
//   KOKORO_VOICE      Voice name, default af_sky

import OpenAI from "openai";
import { spawn } from "node:child_process";
import { Readable } from "node:stream";

// Create an OpenAI client pointed at the local server.
const client = new OpenAI({
  baseURL: process.env.KOKORO_BASE_URL ?? "http://127.0.0.1:8880/v1",
  apiKey: process.env.KOKORO_API_KEY || "not-needed",
});

// Join all command-line words into one sentence.
const text =
  process.argv.slice(2).join(" ") ||
  "This sentence is streamed while it is generated.";

// Choose the voice, defaulting to the voice configured for this setup.
const voice = process.env.KOKORO_VOICE || "af_sky";

// Create a controller so Ctrl+C can cancel the HTTP request.
const controller = new AbortController();

// Ask for raw PCM so playback can start before the full sentence is finished.
const response = await client.audio.speech.create(
  {
    model: "kokoro",
    voice,
    input: text,
    response_format: "pcm",
    stream_format: "audio",
  },
  { signal: controller.signal },
);

// The SDK returns a web Response whose body is the chunked audio stream.
if (!response.body) {
  throw new Error("The server returned no audio body.");
}

// Start ffplay configured for 24 kHz mono signed 16-bit PCM on stdin.
const player = spawn("ffplay", [
  "-nodisp",
  "-autoexit",
  "-loglevel",
  "error",
  "-f",
  "s16le",
  "-ar",
  "24000",
  "-ac",
  "1",
  "-",
]);

// ffplay needs a writable stdin pipe.
if (!player.stdin) {
  throw new Error("Could not open ffplay stdin.");
}

// Pipe the HTTP body into ffplay.
Readable.fromWeb(response.body as never).pipe(player.stdin);

// Report a missing or broken ffplay installation.
player.on("error", (error) => {
  console.error(`Could not start ffplay: ${error.message}`);
  process.exitCode = 1;
});

// Exit with ffplay's status when playback ends.
player.on("close", (code) => {
  process.exit(code ?? 0);
});

// On Ctrl+C, cancel the request and stop playback.
process.on("SIGINT", () => {
  controller.abort();
  player.kill("SIGTERM");
});
