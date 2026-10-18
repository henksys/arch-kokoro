#!/usr/bin/env bash
# ==============================================================================
# End-to-end tests for the local Kokoro TTS API
# ==============================================================================
# Usage:
#   ./test.sh            Run the full test suite
#   ./test.sh --quick    Run only health, voices, and one MP3 synthesis
#   ./test.sh --help     Show this help
#
# The script reads the same config file as the service, so it automatically
# tests the correct host, port, and API key.
# ==============================================================================

# Stop on errors, undefined variables, and failed pipeline stages.
set -euo pipefail

# Resolve the absolute path of this project directory.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Locate the user configuration file.
CONFIG_FILE="$HOME/.config/kokoro-tts/env"

# Load the service configuration when it exists.
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# Read the configured host, falling back to loopback.
HOST="${KOKORO_HOST:-127.0.0.1}"

# Read the configured port, falling back to 8880.
PORT="${KOKORO_PORT:-8880}"

# Convert a wildcard bind address into a loopback address for local testing.
if [ "$HOST" = "0.0.0.0" ] || [ "$HOST" = "::" ]; then
  # The wildcard address is reachable through IPv4 loopback.
  HOST="127.0.0.1"
fi

# Build the API base URL.
BASE="http://$HOST:$PORT"

# Build an optional Authorization header array.
AUTH=()
# Add the bearer token only when one is configured.
if [ -n "${KOKORO_API_KEY:-}" ]; then
  # Store the header as one array element so spaces are preserved.
  AUTH=(-H "Authorization: Bearer $KOKORO_API_KEY")
fi

# Default voice used by the tests.
VOICE="${KOKORO_DEFAULT_VOICE:-af_sky}"

# Create a temporary directory for generated audio.
TMP_DIR="$(mktemp -d)"

# Remove the temporary directory when the script exits, regardless of status.
trap 'rm -rf "$TMP_DIR"' EXIT

# Count successful checks.
PASS_COUNT=0

# Count failed checks.
FAIL_COUNT=0

# Print a passing check and increment the counter.
pass() {
  # The first argument is the human-readable check name.
  printf 'PASS  %s\n' "$1"
  # Increment the success counter.
  PASS_COUNT=$((PASS_COUNT + 1))
}

# Print a failing check and increment the counter.
fail() {
  # The first argument is the human-readable check name.
  printf 'FAIL  %s\n' "$1"
  # Increment the failure counter.
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Show usage information.
show_help() {
  # Print the supported command-line modes.
  printf 'Usage: %s [--quick|--help]\n' "$(basename "$0")"
}

# Parse the optional command-line mode.
MODE="full"
# Only one argument is supported.
if [ "$#" -gt 1 ]; then
  # Reject extra arguments.
  show_help
  # Exit with a usage error.
  exit 2
fi
# Handle the single argument when one was provided.
if [ "$#" -eq 1 ]; then
  # Store the requested mode.
  case "$1" in
    --quick)
      # Run the short smoke test used by the installer.
      MODE="quick"
      ;;
    --help|-h)
      # Show help and exit successfully.
      show_help
      # Stop without running tests.
      exit 0
      ;;
    *)
      # Reject unknown options.
      show_help
      # Exit with a usage error.
      exit 2
      ;;
  esac
fi

# Print a small header so test output is easy to read.
printf 'Testing Kokoro TTS at %s\n\n' "$BASE"

# Check the health endpoint.
if health_json="$(curl -fsS "${AUTH[@]}" "$BASE/health" 2>/dev/null)" && printf '%s' "$health_json" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  # Report the loaded model and voice count from the health response.
  printf '      %s\n' "$(printf '%s' "$health_json" | jq -c '{model_file,voices,threads}')"
  # Mark the health check as successful.
  pass "health endpoint is ready"
else
  # Mark the health check as failed.
  fail "health endpoint is ready"
fi

# Check that the voice list contains the requested voice.
if voices_json="$(curl -fsS "${AUTH[@]}" "$BASE/v1/audio/voices" 2>/dev/null)" && printf '%s' "$voices_json" | jq -e --arg voice "$VOICE" '.voices | map(.id) | index($voice) != null' >/dev/null 2>&1; then
  # Report the number of voices returned by the API.
  printf '      %s voices available\n' "$(printf '%s' "$voices_json" | jq '.voices | length')"
  # Mark the voice-list check as successful.
  pass "voice list contains $VOICE"
else
  # Mark the voice-list check as failed.
  fail "voice list contains $VOICE"
fi

# Check that the model list includes the local model name.
if models_json="$(curl -fsS "${AUTH[@]}" "$BASE/v1/models" 2>/dev/null)" && printf '%s' "$models_json" | jq -e '.data | map(.id) | index("kokoro") != null' >/dev/null 2>&1; then
  # Mark the model-list check as successful.
  pass "model list contains kokoro"
else
  # Mark the model-list check as failed.
  fail "model list contains kokoro"
fi

# Build a reusable JSON request body for MP3 synthesis.
MP3_PAYLOAD="$(jq -n --arg voice "$VOICE" '{model:"kokoro",input:"Hello from the local Kokoro test suite.",voice:$voice,response_format:"mp3",speed:1.0}')"

# Generate one MP3 file.
if curl -fsS "${AUTH[@]}" "$BASE/v1/audio/speech" -H 'Content-Type: application/json' -d "$MP3_PAYLOAD" -o "$TMP_DIR/test.mp3" 2>/dev/null && [ -s "$TMP_DIR/test.mp3" ]; then
  # Verify that ffmpeg can decode the generated MP3.
  if ffmpeg -v error -i "$TMP_DIR/test.mp3" -f null - >/dev/null 2>&1; then
    # Mark the MP3 check as successful.
    pass "MP3 synthesis produces decodable audio"
  else
    # Mark the MP3 check as failed when the file is corrupt.
    fail "MP3 synthesis produces decodable audio"
  fi
else
  # Mark the MP3 check as failed when the request failed.
  fail "MP3 synthesis produces decodable audio"
fi

# Stop here for the quick mode used by the installer.
if [ "$MODE" = "quick" ]; then
  # Print a summary of the quick test.
  printf '\nQuick test: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
  # Return a non-zero status when anything failed.
  [ "$FAIL_COUNT" -eq 0 ]
  # Leave the script.
  exit $?
fi

# Test OpenAI model/voice aliases and the ignored instructions field.
payload='{"model":"tts-1","input":"OpenAI alias compatibility test.","voice":"shimmer","response_format":"wav","instructions":"This field is accepted but ignored."}'
if curl -fsS "${AUTH[@]}" "$BASE/v1/audio/speech" -H 'Content-Type: application/json' -d "$payload" -o "$TMP_DIR/alias.wav" 2>/dev/null && ffmpeg -v error -i "$TMP_DIR/alias.wav" -f null - >/dev/null 2>&1; then
  # Mark the compatibility check as successful.
  pass "OpenAI model, voice alias, and instructions are accepted"
else
  # Mark the compatibility check as failed.
  fail "OpenAI model, voice alias, and instructions are accepted"
fi

# Test every OpenAI response format.
for format in mp3 wav pcm flac opus aac; do
  # Build the request body for this format.
  payload="$(jq -n --arg voice "$VOICE" --arg format "$format" '{model:"kokoro",input:"The quick brown fox jumps over the lazy dog.",voice:$voice,response_format:$format,speed:1.0}')"
  # Generate the audio file.
  if curl -fsS "${AUTH[@]}" "$BASE/v1/audio/speech" -H 'Content-Type: application/json' -d "$payload" -o "$TMP_DIR/format.$format" 2>/dev/null && [ -s "$TMP_DIR/format.$format" ]; then
    # PCM is raw data, so only check that it has a plausible number of samples.
    if [ "$format" = "pcm" ]; then
      # Require at least half a second of 24 kHz 16-bit mono audio.
      if [ "$(stat -c '%s' "$TMP_DIR/format.$format")" -gt 24000 ]; then
        # Mark the PCM check as successful.
        pass "PCM synthesis produces raw audio"
      else
        # Mark the PCM check as failed when the file is too small.
        fail "PCM synthesis produces raw audio"
      fi
    elif ffmpeg -v error -i "$TMP_DIR/format.$format" -f null - >/dev/null 2>&1; then
      # Mark compressed/container format checks as successful.
      pass "$format synthesis produces decodable audio"
    else
      # Mark format checks as failed when the file is corrupt.
      fail "$format synthesis produces decodable audio"
    fi
  else
    # Mark format checks as failed when the request failed.
    fail "$format synthesis produces decodable audio"
  fi
done

# Test that extreme OpenAI speeds are accepted.
for speed in 0.25 4.0; do
  # Build a WAV request with the requested speed.
  payload="$(jq -n --arg voice "$VOICE" --argjson speed "$speed" '{model:"kokoro",input:"Speed test.",voice:$voice,response_format:"wav",speed:$speed}')"
  # Generate the audio file.
  if curl -fsS "${AUTH[@]}" "$BASE/v1/audio/speech" -H 'Content-Type: application/json' -d "$payload" -o "$TMP_DIR/speed-$speed.wav" 2>/dev/null && ffmpeg -v error -i "$TMP_DIR/speed-$speed.wav" -f null - >/dev/null 2>&1; then
    # Mark the speed check as successful.
    pass "speed $speed is accepted"
  else
    # Mark the speed check as failed.
    fail "speed $speed is accepted"
  fi
done

# Test PCM streaming.
payload="$(jq -n --arg voice "$VOICE" '{model:"kokoro",input:"PCM streaming test. This audio is sent while it is generated.",voice:$voice,response_format:"pcm",stream_format:"audio"}')"
if curl -fsS "${AUTH[@]}" "$BASE/v1/audio/speech" -H 'Content-Type: application/json' -d "$payload" -o "$TMP_DIR/stream.pcm" 2>/dev/null && [ "$(stat -c '%s' "$TMP_DIR/stream.pcm")" -gt 24000 ]; then
  # Mark the PCM streaming check as successful.
  pass "PCM streaming returns audio"
else
  # Mark the PCM streaming check as failed.
  fail "PCM streaming returns audio"
fi

# Test SSE streaming.
payload="$(jq -n --arg voice "$VOICE" '{model:"kokoro",input:"SSE streaming test.",voice:$voice,response_format:"pcm",stream_format:"sse"}')"
if curl -sS -N "${AUTH[@]}" "$BASE/v1/audio/speech" -H 'Content-Type: application/json' -d "$payload" -o "$TMP_DIR/stream.sse" 2>/dev/null && grep -q '"type":"speech.audio.delta"' "$TMP_DIR/stream.sse" && grep -q '"type":"speech.audio.done"' "$TMP_DIR/stream.sse"; then
  # Mark the SSE check as successful.
  pass "SSE streaming emits delta and done events"
else
  # Mark the SSE check as failed.
  fail "SSE streaming emits delta and done events"
fi

# Test that an unknown voice is rejected with an OpenAI-shaped 400 error.
payload='{"model":"kokoro","input":"Error test.","voice":"not_a_real_voice"}'
status_code="$(curl -sS -o "$TMP_DIR/error.json" -w '%{http_code}' "${AUTH[@]}" "$BASE/v1/audio/speech" -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"
if [ "$status_code" = "400" ] && jq -e '.error.type == "invalid_request_error"' "$TMP_DIR/error.json" >/dev/null 2>&1; then
  # Mark the error-shape check as successful.
  pass "unknown voices return an OpenAI-style 400 error"
else
  # Mark the error-shape check as failed.
  fail "unknown voices return an OpenAI-style 400 error"
fi

# Print the final summary.
printf '\nFull test: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

# Return a non-zero status when anything failed.
[ "$FAIL_COUNT" -eq 0 ]
