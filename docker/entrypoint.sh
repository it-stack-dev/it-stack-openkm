#!/bin/bash
# entrypoint.sh — IT-Stack openkm container entrypoint
set -euo pipefail

echo "Starting IT-Stack OPENKM (Module 14)..."

# Source any environment overrides
if [ -f /opt/it-stack/openkm/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/openkm/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
