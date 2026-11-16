#!/usr/bin/env bash
# aisha one-command installer:
#   curl -fsSL https://github.com/buratinodev/aisha/releases/latest/download/install.sh | bash
#
# Downloads the shim and the Python core, then runs the real installer
# (which checks dependencies and offers to install llm / ollama).
set -euo pipefail

# Latest GitHub release; set AISHA_REPO_RAW to the raw main-branch URL to
# install unreleased code instead.
REPO_RAW="${AISHA_REPO_RAW:-https://github.com/buratinodev/aisha/releases/latest/download}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading aisha from $REPO_RAW ..."
curl -fsSL "$REPO_RAW/aisha.sh" -o "$tmp/aisha.sh"
curl -fsSL "$REPO_RAW/aisha_core.py" -o "$tmp/aisha_core.py"

# </dev/tty keeps the installer's dependency prompts interactive even though
# this script itself is running from a pipe
if [[ -t 0 ]]; then
  bash "$tmp/aisha.sh" --install
else
  bash "$tmp/aisha.sh" --install < /dev/tty || bash "$tmp/aisha.sh" --install
fi
