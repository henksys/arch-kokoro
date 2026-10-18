#!/usr/bin/env bash
# ==============================================================================
# Kokoro TTS updater
# ==============================================================================
# This simply reruns the idempotent installer. It updates Python dependencies
# when requirements.txt changes, verifies or downloads the selected model, and
# restarts the user service.
#
# Usage:
#   ./update.sh
#   MODEL_VARIANT=fp32 ./update.sh    Switch to the fp32 model
# ==============================================================================

# Stop on errors, undefined variables, and failed pipeline stages.
set -euo pipefail

# Resolve the absolute path of this project directory.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Hand over to the installer, preserving any environment overrides.
exec "$PROJECT_DIR/install.sh" "$@"
