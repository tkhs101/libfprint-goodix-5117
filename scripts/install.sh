#!/usr/bin/env bash
# Build and install libfprint with the Goodix 5117 fixes (Debian/Ubuntu).
#
#   ./install.sh [--base-dir DIR]
#
# Clones gulp/libfprint-1 (branch goodix-5117-support), applies the patches,
# builds and installs. The original /usr/lib/.../libfprint-2.so.2.0.0 is backed
# up first so the change can be rolled back.
#
# On Fedora use scripts/install-fedora.sh instead.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${HOME}/src"
PATCH_DIR="$HERE/patches"
PATCH="$PATCH_DIR/0001-goodixtls-make-the-27c6-5117-sensor-usable-end-to-en.patch"
PATCH2="$PATCH_DIR/0002-sigfm-do-not-require-doctest-to-build.patch"
PATCH3="$PATCH_DIR/0003-goodixtls-fix-background-subtraction-wraparound.patch"
SO=/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0
# Keep the backup out of the library directories: ldconfig would otherwise
# treat it as another provider of libfprint-2.so.2 and fprintd can end up
# loading the unpatched library.
BACKUP_DIR=/var/backups/libfprint-goodix5117

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v meson >/dev/null || die "meson not found: sudo apt install meson ninja-build"
command -v pkg-config >/dev/null || die "pkg-config not found"
pkg-config --exists gnutls || die "GnuTLS headers not found: sudo apt install libgnutls28-dev"
pkg-config --exists opencv4 || die "OpenCV headers not found: sudo apt install libopencv-dev"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

if [ ! -d libfprint-1 ]; then
  say "cloning gulp/libfprint-1 (goodix-5117-support)"
  git clone -b goodix-5117-support https://github.com/gulp/libfprint-1.git
else
  say "reusing existing $BASE_DIR/libfprint-1"
fi
cd libfprint-1

if git log --oneline | grep -q "make the 27c6:5117 sensor usable"; then
  say "patch 0001 already applied"
else
  say "applying $PATCH"
  git am "$PATCH" || die "patch 0001 did not apply cleanly (git am --abort to reset)"
fi

if git log --oneline | grep -q "do not require doctest"; then
  say "patch 0002 already applied"
else
  say "applying $PATCH2"
  git am "$PATCH2" || die "patch 0002 did not apply cleanly (git am --abort to reset)"
fi

if git log --oneline | grep -q "background subtraction wraparound"; then
  say "patch 0003 already applied"
else
  say "applying patch 0003"
  git am "$PATCH3" || die "patch 0003 did not apply cleanly (git am --abort to reset)"
fi

say "configuring"
MESON_ARGS=(
  --prefix=/usr
  -Ddrivers=goodixtls511
  -Dudev_rules=disabled
  -Dudev_hwdb=disabled
)
if [ -d build ]; then
  meson setup build --reconfigure "${MESON_ARGS[@]}" >/dev/null
else
  meson setup build "${MESON_ARGS[@]}" >/dev/null
fi

say "building"
ninja -C build

sudo mkdir -p "$BACKUP_DIR"

# Older versions kept the backup next to the library; move it away.
if [ -e "${SO}.bak-goodix5117" ]; then
  say "moving stale backup ${SO}.bak-goodix5117 -> $BACKUP_DIR"
  sudo mv "${SO}.bak-goodix5117" "$BACKUP_DIR/"
fi

if [ -f "$SO" ] && [ ! -f "$BACKUP_DIR/$(basename "$SO")" ]; then
  say "backing up $SO -> $BACKUP_DIR/$(basename "$SO")"
  sudo cp -a "$SO" "$BACKUP_DIR/"
fi

say "installing"
sudo ninja -C build install
if command -v restorecon >/dev/null; then
  sudo restorecon "$SO" || true
fi
sudo ldconfig
sudo systemctl restart fprintd || true

cat <<MSG

Done. Next:

  sudo mkdir -p /etc/goodix5117
  # only if the sensor is NOT factory-provisioned:
  #   printf '%s\n' "<64 hex digits>" | sudo tee /etc/goodix5117/psk
  #   sudo chmod 600 /etc/goodix5117/psk
  fprintd-enroll

Roll back with:
  sudo install -m 755 $BACKUP_DIR/$(basename "$SO") $SO && sudo ldconfig && sudo systemctl restart fprintd

If the sensor still refuses the handshake, it carries a per-device key:
see docs/psk-write-findings.md.
MSG
