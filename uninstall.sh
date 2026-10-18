#!/usr/bin/env bash
# ==============================================================================
# Kokoro TTS uninstaller
# ==============================================================================
# Usage:
#   ./uninstall.sh             Stop the service and remove the systemd unit
#   ./uninstall.sh --purge     Also delete models, the virtual environment, and
#                              the user configuration (asks for confirmation)
#   ./uninstall.sh --purge --yes
#                              Delete everything without asking
#
# This script does not remove uv, ffmpeg, or enable/disable linger; those are
# shared user/system tools.
# ==============================================================================

# Stop on errors, undefined variables, and failed pipeline stages.
set -euo pipefail

# Resolve the absolute path of this project directory.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Define the runtime and configuration directories used by the installer.
RUNTIME_DIR="${KOKORO_RUNTIME_DIR:-$HOME/.local/share/kokoro-tts}"
CONFIG_DIR="${KOKORO_CONFIG_DIR:-$HOME/.config/kokoro-tts}"

# Define the systemd user unit location.
UNIT_FILE="$HOME/.config/systemd/user/kokoro-tts.service"

# Default to keeping user data.
PURGE="false"

# Default to asking before deleting anything.
ASSUME_YES="false"

# Parse the supported command-line options.
for argument in "$@"; do
  # Select purge mode.
  case "$argument" in
    --purge)
      # Enable deletion of runtime and config data.
      PURGE="true"
      ;;
    --yes|-y)
      # Skip the confirmation prompt.
      ASSUME_YES="true"
      ;;
    --help|-h)
      # Show usage and exit.
      printf 'Usage: %s [--purge] [--yes]\n' "$(basename "$0")"
      # Stop successfully.
      exit 0
      ;;
    *)
      # Reject unknown arguments.
      printf 'Unknown option: %s\n' "$argument" >&2
      # Exit with a usage error.
      exit 2
      ;;
  esac
done

# Stop and disable the user service when systemd is available.
if systemctl --user show-environment >/dev/null 2>&1; then
  # Disable and stop the service; ignore a missing unit on a fresh system.
  systemctl --user disable --now kokoro-tts.service 2>/dev/null || true
fi

# Remove the unit file when it exists.
if [ -f "$UNIT_FILE" ]; then
  # Delete the unit file.
  rm -f "$UNIT_FILE"
  # Report the removal.
  printf 'Removed %s\n' "$UNIT_FILE"
fi

# Remove the enablement symlink even when systemd was not reachable.
rm -f "$HOME/.config/systemd/user/default.target.wants/kokoro-tts.service"

# Reload systemd so it forgets the removed unit.
if systemctl --user show-environment >/dev/null 2>&1; then
  # Ask systemd to reload unit definitions.
  systemctl --user daemon-reload
fi

# Keep runtime and configuration data unless the user asked for a purge.
if [ "$PURGE" != "true" ]; then
  # Explain what was kept.
  printf 'Kept runtime data in %s\n' "$RUNTIME_DIR"
  printf 'Kept configuration in %s\n' "$CONFIG_DIR"
  printf 'Run %s --purge to remove those directories as well.\n' "$0"
  # Stop successfully.
  exit 0
fi

# Ask for confirmation unless --yes was supplied.
if [ "$ASSUME_YES" != "true" ]; then
  # Warn about permanent deletion.
  printf 'This will permanently delete %s and %s.\n' "$RUNTIME_DIR" "$CONFIG_DIR"
  # Read the user's answer.
  read -r -p 'Continue? [y/N] ' answer
  # Accept only a leading y or Y.
  case "$answer" in
    y|Y|yes|YES)
      # Continue with deletion.
      ;;
    *)
      # Abort without deleting anything.
      printf 'Aborted.\n'
      # Stop successfully.
      exit 0
      ;;
  esac
fi

# Delete the runtime directory (venv, models, caches).
rm -rf "$RUNTIME_DIR"

# Delete the configuration directory (environment file, API key).
rm -rf "$CONFIG_DIR"

# Report completion.
printf 'Kokoro TTS runtime and configuration removed.\n'
