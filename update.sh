#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPT_DIR"

echo "Pulling latest version..."
git pull --ff-only

echo
echo "Installing latest version..."
exec "$SCRIPT_DIR/install.sh" "$@"
