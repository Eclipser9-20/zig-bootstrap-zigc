#!/usr/bin/env bash
# Installs ziggy (this repo's Zig fork, with vendored llvm-tools nm/objdump)
# system-wide (or per-user, if not run as root) on Linux/macOS, FROM A LOCAL
# BUILD — there is no GitHub Releases artifact for ziggy yet.
#
# Prerequisite: build it first with `./build <target> <mcpu>`, which
# produces a flat install tree at out/zig-<target>-<mcpu>/ (binary at the
# root of that dir, e.g. out/zig-native-linux-gnu-baseline/zig). This
# script copies that whole tree into place and renames the binary to
# "ziggy" so it doesn't collide with a real Zig install.
#
# Layout:
#   $LOCAL/ziggy/          the copied build output (ziggy binary, lib/, doc/, ...)
#   $LOCAL/bin/ziggy        a symlink to $LOCAL/ziggy/ziggy (on the standard PATH)
#
# When run as root, $LOCAL defaults to /usr/local, $LOCAL/ziggy is owned by
# a dedicated "_ZIGGYmaintenance" group (setgid, group-writable), and the
# invoking user (the one who ran `sudo ./install.sh`, if any) is added to
# that group — so re-running this script to pick up a newer local build
# works afterward without needing sudo again. Anyone else on the machine
# can still run ziggy, just not overwrite it, unless an admin adds them to
# the group too (`sudo usermod -aG _ZIGGYmaintenance <user>` on Linux, or
# the macOS equivalent below). The leading underscore follows macOS's
# convention for system/service groups that don't show up as regular
# user-facing groups.
#
# When run as a normal user with no root available, everything installs
# under $HOME/.local instead, owned by that user — no group needed, since
# the user already owns everything they'd want to update.
#
# Re-running this script (fresh install or update) always overwrites
# $LOCAL/ziggy in place — that's the whole self-update story for now,
# until ziggy gets its own --update subcommand.
#
# Usage:
#   ./install.sh [--from <path-to-build-output>]
#
# Without --from, the most recently modified out*/zig-*/ or
# out-win*/zig-*/ (if run under WSL against a Windows checkout) directory
# is auto-detected.

set -euo pipefail

GROUP_NAME="_ZIGGYmaintenance"
FROM=""

while [ $# -gt 0 ]; do
    case "$1" in
    --from)
        FROM="$2"
        shift 2
        ;;
    --from=*)
        FROM="${1#--from=}"
        shift
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "Usage: $0 [--from <path-to-build-output>]" >&2
        exit 1
        ;;
    esac
done

ROOTDIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$FROM" ]; then
    # Auto-detect the most recently modified out*/zig-*/ directory.
    FROM=$(
        find "$ROOTDIR" -maxdepth 2 -type d -name 'zig-*' -path '*/out*/*' 2>/dev/null |
            xargs -I{} sh -c 'printf "%s\t%s\n" "$(stat -c %Y "{}" 2>/dev/null || stat -f %m "{}")" "{}"' |
            sort -rn |
            head -1 |
            cut -f2-
    )
fi

if [ -z "$FROM" ] || [ ! -d "$FROM" ]; then
    echo "error: no build output found — run ./build <target> <mcpu> first" >&2
    echo "       (or pass --from <path-to-build-output> to point at one explicitly)" >&2
    exit 1
fi

SRC_BIN="$FROM/zig"
if [ ! -f "$SRC_BIN" ] || [ ! -x "$SRC_BIN" ]; then
    echo "error: no build output found — '$FROM' doesn't contain a 'zig' binary." >&2
    echo "       Run ./build <target> <mcpu> first, or pass --from <path-to-build-output>." >&2
    exit 1
fi

echo "==> Installing ziggy from local build: $FROM"

am_root=false
if [ "$(id -u)" -eq 0 ]; then am_root=true; fi

if $am_root; then
    LOCAL="/usr/local"
    INSTALL_USER="${SUDO_USER:-root}"
else
    LOCAL="$HOME/.local"
    INSTALL_USER="$(id -un)"
fi

ZIGGY_HOME="$LOCAL/ziggy"
UPDATING=false
if [ -d "$ZIGGY_HOME" ]; then
    UPDATING=true
fi

os="$(uname -s)"
case "$os" in
Linux) platform="linux" ;;
Darwin) platform="macos" ;;
*)
    echo "Unsupported OS: $os" >&2
    exit 1
    ;;
esac

if $UPDATING; then
    echo "==> $ZIGGY_HOME already exists — updating in place"
else
    echo "==> Installing ziggy to $ZIGGY_HOME"
fi

mkdir -p "$LOCAL/bin"

# Copy the whole build output tree (binary + lib/ + doc/ + ...), then
# overwrite/replace whatever was there before.
TMP_HOME="$LOCAL/.ziggy.new.$$"
rm -rf "$TMP_HOME"
mkdir -p "$TMP_HOME"
cp -R "$FROM/." "$TMP_HOME/"

# Rename the copied "zig" binary to "ziggy" in place, so it doesn't
# collide with a real Zig toolchain on the same machine.
if [ ! -f "$TMP_HOME/zig" ]; then
    rm -rf "$TMP_HOME"
    echo "error: unexpected build output layout — no 'zig' binary at the root of $FROM" >&2
    exit 1
fi
mv "$TMP_HOME/zig" "$TMP_HOME/ziggy"
chmod +x "$TMP_HOME/ziggy"

rm -rf "$ZIGGY_HOME"
mv "$TMP_HOME" "$ZIGGY_HOME"

ln -sf "../ziggy/ziggy" "$LOCAL/bin/ziggy"

if $am_root; then
    # Set up the shared-maintenance group.
    if [ "$platform" = "macos" ]; then
        if ! dscl . -read "/Groups/$GROUP_NAME" >/dev/null 2>&1; then
            next_gid=$(dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | sort -n | tail -1)
            next_gid=$((next_gid + 1))
            dseditgroup -o create -i "$next_gid" "$GROUP_NAME"
        fi
        if [ "$INSTALL_USER" != "root" ]; then
            dseditgroup -o edit -a "$INSTALL_USER" -t user "$GROUP_NAME"
        fi
    else
        if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
            groupadd "$GROUP_NAME"
        fi
        if [ "$INSTALL_USER" != "root" ]; then
            usermod -aG "$GROUP_NAME" "$INSTALL_USER"
        fi
    fi

    chgrp -R "$GROUP_NAME" "$ZIGGY_HOME"
    # setgid on directories so new files (e.g. from a re-run of this
    # script) inherit the group automatically; rwxrwsr-x on dirs,
    # rwxrwxr-x on files.
    find "$ZIGGY_HOME" -type d -exec chmod 2775 {} +
    find "$ZIGGY_HOME" -type f -exec chmod 0664 {} +
    chmod 0775 "$ZIGGY_HOME/ziggy"

    echo "==> $ZIGGY_HOME is owned by the '$GROUP_NAME' group (setgid, group-writable)."
    if [ "$INSTALL_USER" != "root" ]; then
        echo "    $INSTALL_USER was added to it — log out/in (or run 'newgrp $GROUP_NAME')"
        echo "    for that to take effect in your current shell."
    fi
    echo "    To let another user re-run install.sh without sudo: sudo usermod -aG $GROUP_NAME <user>  (Linux)"
    echo "                                                         sudo dseditgroup -o edit -a <user> -t user $GROUP_NAME  (macOS)"
else
    chmod -R u+rwX,go+rX,go-w "$ZIGGY_HOME"
fi

echo "==> Installed: $ZIGGY_HOME/ziggy"
echo "==> Symlinked: $LOCAL/bin/ziggy -> $ZIGGY_HOME/ziggy"
if ! echo ":$PATH:" | grep -q ":$LOCAL/bin:"; then
    echo "==> $LOCAL/bin is not on your PATH. Add this to your shell profile:"
    echo "        export PATH=\"$LOCAL/bin:\$PATH\""
fi
echo "==> Open a new shell (or re-source your profile) before 'ziggy version' works."
