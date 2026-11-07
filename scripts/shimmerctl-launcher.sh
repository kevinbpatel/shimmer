#!/bin/sh
# Locate a user-installed Python without triggering macOS's developer-tools installer.
set -eu
CLI_RESOURCES=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Installed command is a symlink; follow it before locating the bundled payload.
if [ -L "$0" ]; then
    CLI_TARGET=$(readlink "$0")
    CLI_RESOURCES=$(CDPATH= cd -- "$(dirname -- "$CLI_TARGET")" && pwd)
fi
for CLI_PYTHON in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$CLI_PYTHON" ]; then exec "$CLI_PYTHON" "$CLI_RESOURCES/shimmerctl.py" "$@"; fi
done
CLI_PYTHON=$(command -v python3 || true)
if [ -n "$CLI_PYTHON" ] && [ "$CLI_PYTHON" != /usr/bin/python3 ]; then
    exec "$CLI_PYTHON" "$CLI_RESOURCES/shimmerctl.py" "$@"
fi
if /usr/bin/xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
    exec /usr/bin/python3 "$CLI_RESOURCES/shimmerctl.py" "$@"
fi
printf '%s\n' '{"error":"Python 3 is required for shimmerctl. Install Python 3 and try again."}' >&2
exit 2
