#!/usr/bin/env bash
# ==============================================================================
# Kokoro TTS installer for Omarchy Linux (Arch-based, CPU-only)
# ==============================================================================
# This script installs a small, local, OpenAI-compatible Kokoro TTS server.
# It does not use Docker, does not use an NVIDIA GPU, and does not open any
# firewall ports. The resulting service listens only on 127.0.0.1.
#
# Run it from this directory:
#
#   ./install.sh
#
# Optional environment variables:
#   MODEL_VARIANT=int8|fp32   Model precision (default: int8)
#   KOKORO_PORT=8880          Port for the first installation
#   KOKORO_DEFAULT_VOICE=af_sky
#   KOKORO_THREADS=4
#
# Every functional line below has a human-language comment above it.
# ==============================================================================

# Stop immediately if any command fails, an undefined variable is used, or a
# pipeline command fails.
set -euo pipefail

# Resolve the absolute path of this project directory, regardless of where the
# script was started from.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Store runtime files (virtual environment and models) in the user's local
# share directory, following the XDG convention.
RUNTIME_DIR="${KOKORO_RUNTIME_DIR:-$HOME/.local/share/kokoro-tts}"

# Store user configuration in the user's config directory.
CONFIG_DIR="${KOKORO_CONFIG_DIR:-$HOME/.config/kokoro-tts}"

# The environment file is read by systemd and by the test/client scripts.
CONFIG_FILE="$CONFIG_DIR/env"

# Install the systemd user unit here.
UNIT_DIR="$HOME/.config/systemd/user"

# The unit file name is also the service name used by systemctl.
UNIT_FILE="$UNIT_DIR/kokoro-tts.service"

# Keep the Python virtual environment inside the runtime directory.
VENV_DIR="$RUNTIME_DIR/venv"

# Keep downloaded model files inside the runtime directory.
MODEL_DIR="$RUNTIME_DIR/models"

# Use Python 3.13 because kokoro-onnx does not support Python 3.14 yet, and the
# system Python on current Omarchy releases is 3.14.
PYTHON_VERSION="${PYTHON_VERSION:-3.13}"

# Pin the uv installer version so every machine gets the same toolchain.
UV_VERSION="${UV_VERSION:-0.13.1}"

# Read the model choice from the environment; an empty value means "detect from
# an existing config file, or default to int8".
MODEL_VARIANT="${MODEL_VARIANT:-}"

# Read the existing port, voice, and thread settings from the config file when
# it exists, so rerunning the installer never starts the service on the wrong
# port or with an unexpected voice.
config_value() {
  # The first argument is the key to look for.
  local key="$1"
  # The second argument is the fallback value.
  local fallback="$2"
  # The third argument is a variable that receives the result.
  local value=""
  # Only read the file if it exists.
  if [ -f "$CONFIG_FILE" ]; then
    # Extract the last assignment for the key, ignoring comment lines.
    value="$(sed -n "s/^${key}=//p" "$CONFIG_FILE" | tail -n 1)"
  fi
  # Print the configured value, or the fallback when the key is absent.
  printf '%s' "${value:-$fallback}"
}

# Determine the port: an existing config wins, otherwise use the environment,
# otherwise use 8880.
SERVER_PORT="$(config_value KOKORO_PORT "${KOKORO_PORT:-8880}")"

# Determine the bind address: an existing config wins, otherwise use loopback.
SERVER_HOST="$(config_value KOKORO_HOST "127.0.0.1")"

# Determine the default voice: an existing config wins, otherwise use af_sky.
DEFAULT_VOICE="$(config_value KOKORO_DEFAULT_VOICE "${KOKORO_DEFAULT_VOICE:-af_sky}")"

# Determine the thread count: an existing config wins, otherwise use four.
THREADS="$(config_value KOKORO_THREADS "${KOKORO_THREADS:-4}")"

# If the caller did not pick a model variant, preserve whatever the existing
# config uses; otherwise start with int8 on a fresh installation.
if [ -z "$MODEL_VARIANT" ]; then
  # Prefer fp32 only when the existing config points at the fp32 file.
  if [ -f "$CONFIG_FILE" ] && grep -q '^KOKORO_MODEL_PATH=.*/kokoro-v1.0.onnx$' "$CONFIG_FILE"; then
    MODEL_VARIANT="fp32"
  else
    MODEL_VARIANT="int8"
  fi
fi

# Validate the model variant before doing any work.
case "$MODEL_VARIANT" in
  int8)
    # The int8 model is the smallest and fastest option.
    MODEL_FILE_NAME="kokoro-v1.0.int8.onnx"
    # Pinned download URL for the int8 ONNX export.
    MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/kokoro-v1.0.int8.onnx"
    # SHA256 checksum for the int8 ONNX file.
    MODEL_SHA256="ae315a79b623f244700e4afb9246c46a26066782e049ba174bf3ba433970ee9c"
    ;;
  fp32)
    # The fp32 model is larger but has the highest quality.
    MODEL_FILE_NAME="kokoro-v1.0.onnx"
    # Pinned download URL for the fp32 ONNX export.
    MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/kokoro-v1.0.onnx"
    # SHA256 checksum for the fp32 ONNX file.
    MODEL_SHA256="beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a"
    ;;
  *)
    # Refuse unknown variants instead of guessing.
    printf 'ERROR: MODEL_VARIANT must be int8 or fp32, got %s\n' "$MODEL_VARIANT" >&2
    exit 1
    ;;
esac

# The voices file is shared by both model precisions.
VOICES_FILE_NAME="voices-v1.0.bin"

# Pinned download URL for the 54-voice pack.
VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/voices-v1.0.bin"

# SHA256 checksum for the voices file.
VOICES_SHA256="bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"

# Absolute path of the selected model file.
MODEL_PATH="$MODEL_DIR/$MODEL_FILE_NAME"

# Absolute path of the voices file.
VOICES_PATH="$MODEL_DIR/$VOICES_FILE_NAME"

# Print a short status line with a consistent prefix.
log() {
  # Send the message to standard output.
  printf '[kokoro] %s\n' "$*"
}

# Print an error and stop the installer.
die() {
  # Send the message to standard error.
  printf '[kokoro] ERROR: %s\n' "$*" >&2
  # Exit with a non-zero status.
  exit 1
}

# Check that the required command-line tools are available before changing
# anything.
for required_command in curl ffmpeg ffprobe sha256sum ss systemctl loginctl jq; do
  # Fail with an actionable message when a tool is missing.
  command -v "$required_command" >/dev/null 2>&1 || die "Missing required command: $required_command"
done

# Confirm that this is an Arch-based Omarchy system.
if [ ! -r /etc/os-release ]; then
  # The distribution identity file is required.
  die "/etc/os-release is missing or unreadable"
fi

# Load the distribution identity variables (ID, ID_LIKE, and so on).
# shellcheck disable=SC1091
. /etc/os-release

# Accept Omarchy itself and any Arch-like derivative.
if [ "${ID:-}" != "omarchy" ] && [[ "${ID_LIKE:-}" != *arch* ]]; then
  # Refuse to continue on an unsupported distribution.
  die "This installer targets Omarchy/Arch Linux; detected ID=${ID:-unknown}"
fi

# Accept the CPU architectures for which ONNX Runtime publishes wheels.
case "$(uname -m)" in
  x86_64|aarch64)
    # These architectures are supported.
    ;;
  *)
    # Refuse unknown architectures.
    die "Unsupported CPU architecture: $(uname -m)"
    ;;
esac

# Confirm that the user's systemd manager is reachable.
systemctl --user show-environment >/dev/null 2>&1 || die "The systemd user manager is not available"

# Check whether something is already listening on the configured port.
if ss -H -ltn "sport = :$SERVER_PORT" | grep -q .; then
  # Accept the port when the process answering is an existing Kokoro service.
  if curl -fsS "http://127.0.0.1:$SERVER_PORT/health" 2>/dev/null | grep -q '"model":"kokoro"'; then
    # Report that this is an idempotent reinstall.
    log "Existing Kokoro service detected on port $SERVER_PORT"
  else
    # Refuse to collide with an unrelated service.
    die "Port $SERVER_PORT is already in use by another service"
  fi
fi

# Create the runtime and configuration directories.
mkdir -p "$RUNTIME_DIR" "$MODEL_DIR" "$CONFIG_DIR"

# If uv is already installed, use it; otherwise install a pinned uv into the
# user's ~/.local/bin directory without touching the system Python.
if command -v uv >/dev/null 2>&1; then
  # Remember the absolute path so later commands use the same binary.
  UV_BIN="$(command -v uv)"
elif [ -x "$HOME/.local/bin/uv" ]; then
  # Use an existing user-local uv even when ~/.local/bin is not on PATH.
  UV_BIN="$HOME/.local/bin/uv"
  # Add the directory to this script's PATH for any child commands.
  export PATH="$HOME/.local/bin:$PATH"
else
  # Create the user-local binary directory.
  mkdir -p "$HOME/.local/bin"
  # Download and run the pinned uv installer.
  curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh
  # Add the user-local binary directory to this script's PATH.
  export PATH="$HOME/.local/bin:$PATH"
  # Verify that the installer produced a working uv binary.
  command -v uv >/dev/null 2>&1 || die "uv installation failed"
  # Remember the absolute path of the new binary.
  UV_BIN="$(command -v uv)"
fi

# Print the uv version for the installation log.
log "Using $("$UV_BIN" --version)"

# Install the managed Python interpreter if it is not already present.
"$UV_BIN" python install "$PYTHON_VERSION"

# If the virtual environment is missing or broken, recreate it.
if [ ! -x "$VENV_DIR/bin/python" ]; then
  # Create a fresh virtual environment with the pinned Python version.
  "$UV_BIN" venv --python "$PYTHON_VERSION" "$VENV_DIR"
fi

# Compute a checksum of the pinned requirements so repeated installs can skip
# unnecessary package work.
REQUIREMENTS_HASH="$(sha256sum "$PROJECT_DIR/server/requirements.txt" | awk '{print $1}')"

# Compare the current requirements checksum with the one from the last install.
if [ -f "$VENV_DIR/.requirements.sha256" ] && [ "$(cat "$VENV_DIR/.requirements.sha256")" = "$REQUIREMENTS_HASH" ]; then
  # The installed packages already match the lockfile.
  log "Python dependencies are already up to date"
else
  # Install exactly the locked package set, copying files instead of hardlinking
  # so the runtime works even when the cache is on another filesystem.
  UV_LINK_MODE=copy "$UV_BIN" pip sync --python "$VENV_DIR/bin/python" "$PROJECT_DIR/server/requirements.txt"
  # Record the requirements checksum for future idempotent runs.
  printf '%s\n' "$REQUIREMENTS_HASH" > "$VENV_DIR/.requirements.sha256"
fi

# Download one file and verify its SHA256 checksum, reusing a valid existing file.
download_verified() {
  # First argument: the download URL.
  local url="$1"
  # Second argument: the destination path.
  local destination="$2"
  # Third argument: the expected SHA256 value.
  local expected_sha256="$3"
  # If the destination already exists and matches, there is nothing to do.
  if [ -f "$destination" ] && printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum -c - >/dev/null 2>&1; then
    # Report the reusable file.
    log "Already present and verified: $(basename "$destination")"
    # Return early from the function.
    return
  fi
  # Remove any stale partial download.
  rm -f "$destination.part"
  # Download to a temporary .part file so a failure cannot corrupt a good file.
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$destination.part" "$url"
  # Verify the downloaded file against the pinned checksum.
  printf '%s  %s\n' "$expected_sha256" "$destination.part" | sha256sum -c -
  # Atomically move the verified file into place.
  mv "$destination.part" "$destination"
}

# Download the selected model and the shared voices file.
download_verified "$MODEL_URL" "$MODEL_PATH" "$MODEL_SHA256"
# Download the shared voices file.
download_verified "$VOICES_URL" "$VOICES_PATH" "$VOICES_SHA256"

# Create a fresh environment file on first install.
if [ ! -f "$CONFIG_FILE" ]; then
  # Write the default configuration with the runtime paths filled in.
  cat > "$CONFIG_FILE" <<EOF
# Kokoro TTS configuration.
# This file is read by systemd and by the helper scripts.
# Keep it private because it can contain an API key.
KOKORO_HOST=$SERVER_HOST
KOKORO_PORT=$SERVER_PORT
KOKORO_DEFAULT_VOICE=$DEFAULT_VOICE
KOKORO_MODEL_PATH=$MODEL_PATH
KOKORO_VOICES_PATH=$VOICES_PATH
KOKORO_THREADS=$THREADS
KOKORO_API_KEY=
KOKORO_CORS_ORIGINS=
KOKORO_LOG_LEVEL=info
EOF
else
  # Preserve the existing file, but update the model paths so a variant change
  # takes effect on the next service restart.
  if grep -q '^KOKORO_MODEL_PATH=' "$CONFIG_FILE"; then
    # Replace the old model path with the selected variant's path.
    sed -i "s|^KOKORO_MODEL_PATH=.*|KOKORO_MODEL_PATH=$MODEL_PATH|" "$CONFIG_FILE"
  else
    # Add the model path when an older config file lacks it.
    printf 'KOKORO_MODEL_PATH=%s\n' "$MODEL_PATH" >> "$CONFIG_FILE"
  fi
  # Update the voices path in the same way.
  if grep -q '^KOKORO_VOICES_PATH=' "$CONFIG_FILE"; then
    # Replace the old voices path.
    sed -i "s|^KOKORO_VOICES_PATH=.*|KOKORO_VOICES_PATH=$VOICES_PATH|" "$CONFIG_FILE"
  else
    # Add the voices path when an older config file lacks it.
    printf 'KOKORO_VOICES_PATH=%s\n' "$VOICES_PATH" >> "$CONFIG_FILE"
  fi
fi

# Make the config private because it can contain a bearer token.
chmod 600 "$CONFIG_FILE"

# Make the helper scripts executable regardless of how the project was copied.
chmod +x "$PROJECT_DIR/install.sh" "$PROJECT_DIR/test.sh" "$PROJECT_DIR/uninstall.sh" "$PROJECT_DIR/update.sh" "$PROJECT_DIR/bin/kokoro-speak" 2>/dev/null || true

# Render the systemd unit template with the absolute paths for this machine.
sed \
  -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
  -e "s|__RUNTIME_DIR__|$RUNTIME_DIR|g" \
  -e "s|__CONFIG_FILE__|$CONFIG_FILE|g" \
  -e "s|__VENV_DIR__|$VENV_DIR|g" \
  "$PROJECT_DIR/systemd/kokoro-tts.service.in" > "$UNIT_FILE"

# Reload systemd so it sees the unit file changes.
systemctl --user daemon-reload

# Enable the service for future logins and boot (when linger is enabled).
systemctl --user enable kokoro-tts.service

# Restart the service so the new code, model, or configuration is active.
systemctl --user restart kokoro-tts.service

# Try to enable linger so the user service starts even before a login. This can
# require a polkit/sudo prompt; if it fails, print the exact command to run.
if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  # Report that boot-time startup is already configured.
  log "Linger is already enabled; the service will start at boot"
elif loginctl enable-linger "$USER" 2>/dev/null; then
  # Report that linger was just enabled.
  log "Linger enabled; the service will start at boot"
else
  # Explain how to enable boot-time startup manually.
  log "WARNING: could not enable linger automatically"
  log "Run: sudo loginctl enable-linger $USER"
fi

# Choose a loopback health-check address even when the service binds 0.0.0.0.
if [ "$SERVER_HOST" = "0.0.0.0" ] || [ "$SERVER_HOST" = "::" ]; then
  # The wildcard address is reachable through IPv4 loopback.
  HEALTH_HOST="127.0.0.1"
else
  # Use the configured address directly.
  HEALTH_HOST="$SERVER_HOST"
fi

# Wait up to 30 seconds for the server to answer its health endpoint.
for attempt in $(seq 1 60); do
  # Stop waiting as soon as the health check succeeds.
  if curl -fsS "http://$HEALTH_HOST:$SERVER_PORT/health" >/dev/null 2>&1; then
    # Leave the loop.
    break
  fi
  # Wait half a second before the next attempt.
  sleep 0.5
done

# Verify that the service actually became healthy.
if ! curl -fsS "http://$HEALTH_HOST:$SERVER_PORT/health" >/dev/null 2>&1; then
  # Show the last service log lines to make the failure diagnosable.
  journalctl --user -u kokoro-tts.service -n 80 --no-pager || true
  # Stop the installer with a clear error.
  die "Kokoro did not become healthy on http://$HEALTH_HOST:$SERVER_PORT"
fi

# Run the quick end-to-end test, including a real af_sky synthesis.
"$PROJECT_DIR/test.sh" --quick

# Print the final usage summary for the user.
printf '\n'
log "Installation complete"
log "API base URL: http://127.0.0.1:$SERVER_PORT/v1"
log "Model: kokoro ($MODEL_VARIANT), default voice: $DEFAULT_VOICE"
log "Service: systemctl --user status kokoro-tts.service"
log "Logs:    journalctl --user -u kokoro-tts.service -f"
log "Test:    $PROJECT_DIR/test.sh"
log "Speak:   $PROJECT_DIR/bin/kokoro-speak \"Hello from Kokoro\""
printf '\n'
