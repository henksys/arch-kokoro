// Speak one sentence with the local Kokoro server and play the result.
//
// Run from this directory:
//   npm install
//   npm run speak -- "Hello from my Node agent"
//
// Environment variables:
//   KOKORO_BASE_URL   API base URL, default http://127.0.0.1:8880/v1
//   KOKORO_API_KEY    Optional bearer token
//   KOKORO_VOICE      Voice name, default af_sky
//   KOKORO_NO_PLAY    Set to 1 to save the file without playing it

import OpenAI from "openai";
import { writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Create an OpenAI client pointed at the local server.
const client = new OpenAI({
  baseURL: process.env.KOKORO_BASE_URL ?? "http://127.0.0.1:8880/v1",
  apiKey: process.env.KOKORO_API_KEY || "not-needed",
});

// Join all command-line words into one sentence.
const text = process.argv.slice(2).join(" ") || "Hello from my Node agent.";

// Choose the voice, defaulting to the voice configured for this setup.
const voice = process.env.KOKORO_VOICE || "af_sky";

// Generate the complete MP3 response.
const response = await client.audio.speech.create({
  model: "kokoro",
  voice,
  input: text,
  response_format: "mp3",
  speed: 1.0,
});

// Write the audio to a temporary file.
const output = join(tmpdir(), "kokoro-node-speak.mp3");
await writeFile(output, Buffer.from(await response.arrayBuffer()));

// Print the saved path so scripts can reuse it.
console.log(output);

// Play the result unless playback was explicitly disabled.
if (process.env.KOKORO_NO_PLAY !== "1") {
  // Spawn mpv and wait for it to finish.
  const player = spawn("mpv", ["--no-video", "--really-quiet", output], {
    stdio: "inherit",
  });

  // Propagate a playback failure to the caller.
  player.on("error", (error) => {
    console.error(`Could not start mpv: ${error.message}`);
    process.exitCode = 1;
  });
}
