#!/usr/bin/env bash
# Removes a system-wide (or per-user) ziggy install done by install.sh.
#
# Removes:
#   $LOCAL/ziggy/          the install directory
#   $LOCAL/bin/ziggy        the PATH symlink
#
# Leaves the "_ZIGGYmaintenance" group in place, since removing a group
# can strand its membership on other machines/tools that reference it by
# name; delete it yourself (groupdel on Linux, dseditgroup -o delete on
# macOS) if you're sure nothing else depends on it.
#
# Run as root to remove a system-wide (/usr/local) install, or as a
# normal user to remove a per-user ($HOME/.local) install.

set -euo pipefail

am_root=false
if [ "$(id -u)" -eq 0 ]; then am_root=true; fi

if $am_root; then
    LOCAL="/usr/local"
else
    LOCAL="$HOME/.local"
fi

ZIGGY_HOME="$LOCAL/ziggy"

if [ -d "$ZIGGY_HOME" ]; then
    rm -rf "$ZIGGY_HOME"
    echo "==> Removed $ZIGGY_HOME"
else
    echo "==> $ZIGGY_HOME not found, nothing to remove there."
fi

if [ -L "$LOCAL/bin/ziggy" ] || [ -e "$LOCAL/bin/ziggy" ]; then
    rm -f "$LOCAL/bin/ziggy"
    echo "==> Removed $LOCAL/bin/ziggy"
fi

echo "==> ziggy has been uninstalled."
