#!/bin/bash
# Install independent console executables. Called by Apple's Installer as root.
# --test-root exercises the identical code in an isolated writable filesystem.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=en_US.UTF-8
unset DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_FRAMEWORK_PATH

ROOT=""
CACHE_IMAGE=""
if [ "${1:-}" = "--test-root" ]; then
    [ "$#" -eq 3 ] && [ -d "$2" ] && [ "$2" != "/" ] || exit 64
    ROOT="$(cd "$2" && pwd -P)"
    CACHE_IMAGE="$3"
else
    [ "$(id -u)" = 0 ] || { echo "Run through the MKVStudio installer."; exit 77; }
    [ "${1:-/}" = "/" ] || { echo "Only the startup volume is supported."; exit 64; }
fi

TOOLS=(mkvmerge mkvinfo mkvextract mkvpropedit)
BASE="$ROOT/Library/Application Support/MKVStudio"
DEST="$BASE/ConsoleTools"
URL="https://mkvtoolnix.download/macos/releases/102.0/MKVToolNix-102.0-2-arm64.dmg"
SHA256="10ebd3b424fd5f4987d50563fc43b5956bf3d4f3bbfa24fa870db956c96578b8"

available() {
    # Do not execute user-controlled programs with Installer's root privileges.
    local name="$1" dir
    for dir in "$ROOT/opt/homebrew/bin" "$ROOT/usr/local/bin" "$DEST/bin"; do
        [ -x "$dir/$name" ] && return 0
    done
    return 1
}

missing=()
for tool in "${TOOLS[@]}"; do
    if ! available "$tool"; then missing+=("$tool"); fi
done
if [ "${#missing[@]}" = 0 ]; then
    echo "All four console utilities are already installed; no downloads or changes."
    exit 0
fi
[ "$(uname -m)" = arm64 ] || { echo "This installer requires Apple Silicon."; exit 65; }
echo "Installing missing console utilities: ${missing[*]}"

# Refuse symlinked private storage: never overwrite another installation.
for part in "$ROOT/Library" "$ROOT/Library/Application Support" "$BASE" "$DEST"; do
    [ ! -L "$part" ] || { echo "Refusing symbolic-link destination: $part"; exit 73; }
done
mkdir -p "$BASE"
LOCK="$BASE/.console-install-lock"
mkdir "$LOCK" || { echo "Another console utility installation is active."; exit 75; }
WORK=""
STAGE=""
MOUNT=""
cleanup() {
    if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet || true; fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    rmdir "$LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ ! -d "$DEST" ]; then
    WORK="$(mktemp -d /private/tmp/MKVStudio-tools.XXXXXX)"
    if [ -n "$CACHE_IMAGE" ]; then
        cp "$CACHE_IMAGE" "$WORK/tools.dmg"
    else
        echo "Downloading verified console utilities (28 MiB)…"
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
            --connect-timeout 20 --max-time 300 --retry 2 "$URL" -o "$WORK/tools.dmg"
    fi
    ACTUAL="$(shasum -a 256 "$WORK/tools.dmg" | awk '{print $1}')"
    [ "$ACTUAL" = "$SHA256" ] || { echo "Console utility download failed SHA-256 verification."; exit 65; }
    mkdir "$WORK/mount"
    hdiutil attach -readonly -nobrowse -mountpoint "$WORK/mount" "$WORK/tools.dmg" -quiet
    MOUNT="$WORK/mount"
    SOURCE="$MOUNT/MKVToolNix.app/Contents/MacOS"
    STAGE="$(mktemp -d "$BASE/.console-stage.XXXXXX")"
    mkdir -p "$STAGE/bin" "$STAGE/share/man/man1" "$STAGE/share/licenses"
    # This is an upstream archive path only. No installed graphical app is used.
    for tool in "${TOOLS[@]}"; do
        ditto --norsrc --noextattr "$SOURCE/$tool" "$STAGE/bin/$tool"
        ditto --norsrc --noextattr "$SOURCE/man/man1/$tool.1" "$STAGE/share/man/man1/$tool.1"
    done
    ditto --norsrc --noextattr "$SOURCE/libs" "$STAGE/bin/libs"
    ditto --norsrc --noextattr "$MOUNT/COPYING.txt" "$STAGE/share/licenses/COPYING.txt"
    printf '%s\nSHA-256: %s\n' "$URL" "$SHA256" > "$STAGE/share/SOURCE.txt"
    # Only pinned, checksum-verified downloads are executed here.
    for tool in "${TOOLS[@]}"; do
        "$STAGE/bin/$tool" --version > "$WORK/version.txt"
        case "$(head -1 "$WORK/version.txt")" in
            "$tool v102.0"*) ;;
            *) echo "Unexpected $tool version."; exit 65 ;;
        esac
    done
    chmod -R go-w "$STAGE"
    chmod 755 "$STAGE"
    # POSIX rename is atomic; the lock serializes our installers.
    [ ! -e "$DEST" ] || { echo "Console destination appeared during installation."; exit 73; }
    mv "$STAGE" "$DEST"
    STAGE=""
fi

for tool in "${TOOLS[@]}"; do
    [ -x "$DEST/bin/$tool" ] || { echo "Incomplete private console installation: $tool"; exit 65; }
done
mkdir -p "$ROOT/usr/local/bin"
for tool in "${missing[@]}"; do
    # Existing files and links, including broken user links, are never replaced.
    if [ ! -e "$ROOT/usr/local/bin/$tool" ] && [ ! -L "$ROOT/usr/local/bin/$tool" ]; then
        ln -s "$DEST/bin/$tool" "$ROOT/usr/local/bin/$tool"
    fi
done
echo "Console utilities installed independently. Existing executables were preserved."
