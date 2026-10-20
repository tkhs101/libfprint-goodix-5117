#!/usr/bin/env bash
# Build and install libfprint with the Goodix 5117 fixes.
#
#   ./install.sh [--base-dir DIR] [--keep]
#
# Clones gulp/libfprint-1 (branch goodix-5117-support), applies the patch,
# builds and installs. The original /usr/lib/.../libfprint-2.so.2.0.0 is backed
# up first so the change can be rolled back.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${HOME}/src"
PATCH="$HERE/patches/0001-goodixtls-make-the-27c6-5117-sensor-usable-end-to-en.patch"
SO=/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0

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
  say "patch already applied"
else
  say "applying $PATCH"
  git am "$PATCH" || die "patch did not apply cleanly (git am --abort to reset)"
fi

say "configuring"
meson setup build --reconfigure \
  -Ddrivers=goodixtls \
  -Dudev_rules=disabled \
  -Dudev_hwdb=disabled >/dev/null

say "building"
ninja -C build

if [ -f "$SO" ] && [ ! -f "${SO}.bak-goodix5117" ]; then
  say "backing up $SO -> ${SO}.bak-goodix5117"
  sudo cp "$SO" "${SO}.bak-goodix5117"
fi

say "installing"
sudo ninja -C build install
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
  sudo cp ${SO}.bak-goodix5117 $SO && sudo ldconfig && sudo systemctl restart fprintd

If the sensor still refuses the handshake, it carries a per-device key:
see docs/psk-write-findings.md.
MSG
