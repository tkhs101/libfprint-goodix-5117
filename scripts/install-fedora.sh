#!/usr/bin/env bash
# Build and install libfprint with the Goodix 5117 fixes on Fedora.
#
#   ./install-fedora.sh [--base-dir DIR] [--no-install] [--skip-deps]
#
# Differences from install.sh (Debian/Ubuntu):
#   * build dependencies come from dnf;
#   * the driver option is "goodixtls511" — "goodixtls" is only a helper and
#     meson fails with "Key goodixtls is not in the dictionary" if selected;
#   * SIGFM (OpenCV) is compiled into the library and patch 0002 drops its
#     hard doctest dependency, because Fedora ships doctest as a CMake-only
#     package without a pkg-config file;
#   * only the shared library is installed, so no libfprint-devel files are
#     overwritten;
#   * the backup is kept outside /usr/lib64, otherwise ldconfig picks it up as
#     another provider of libfprint-2.so.2 and fprintd ends up loading the
#     unpatched library (symptom: "No devices available").
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${HOME}/src"
SO=/usr/lib64/libfprint-2.so.2.0.0
BACKUP_DIR=/var/backups/libfprint-goodix5117
DO_INSTALL=1
SKIP_DEPS=0

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --no-install) DO_INSTALL=0; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -f /etc/fedora-release ] || say "warning: this script targets Fedora, continuing anyway"

if [ "$SKIP_DEPS" -eq 0 ]; then
  # glib2-devel brings glib-mkenums; gcc-c++ and opencv-devel are needed by
  # SIGFM; gnutls-devel replaces the OpenSSL transport; the rest are the
  # regular libfprint dependencies used with the options below.
  DEPS=(
    git meson ninja-build gcc gcc-c++ pkgconf-pkg-config
    glib2-devel libgusb-devel gnutls-devel systemd-devel
    cairo-devel pixman-devel libgudev-devel opencv-devel
  )
  missing=()
  for p in "${DEPS[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    say "installing build dependencies: ${missing[*]}"
    sudo dnf install -y "${missing[@]}"
  fi
fi

command -v meson >/dev/null || die "meson not found"
command -v pkg-config >/dev/null || die "pkg-config not found"
pkg-config --exists gnutls || die "GnuTLS headers not found: sudo dnf install gnutls-devel"
pkg-config --exists opencv4 || die "OpenCV headers not found: sudo dnf install opencv-devel"

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
  say "applying patch 0001"
  git am "$HERE/patches/0001-goodixtls-make-the-27c6-5117-sensor-usable-end-to-en.patch" \
    || die "patch 0001 did not apply cleanly (git am --abort to reset)"
fi

if git log --oneline | grep -q "do not require doctest"; then
  say "patch 0002 already applied"
else
  say "applying patch 0002"
  git am "$HERE/patches/0002-sigfm-do-not-require-doctest-to-build.patch" \
    || die "patch 0002 did not apply cleanly (git am --abort to reset)"
fi

say "configuring"
if [ -d build ]; then
  meson setup build --wipe \
    -Ddrivers=goodixtls511 \
    -Dudev_rules=disabled \
    -Dudev_hwdb=disabled \
    -Ddoc=false \
    -Dintrospection=false >/dev/null
else
  meson setup build \
    -Ddrivers=goodixtls511 \
    -Dudev_rules=disabled \
    -Dudev_hwdb=disabled \
    -Ddoc=false \
    -Dintrospection=false >/dev/null
fi

say "building"
ninja -C build

if [ "$DO_INSTALL" -eq 0 ]; then
  say "built only (--no-install): $(pwd)/build/libfprint/libfprint-2.so.2.0.0"
  exit 0
fi

sudo mkdir -p "$BACKUP_DIR"

# Older revisions of install.sh put the backup next to the library, where
# ldconfig treats it as a second copy of libfprint-2.so.2. Move it away.
for stale in "${SO}.bak-goodix5117"; do
  if [ -e "$stale" ]; then
    say "moving stale backup $stale -> $BACKUP_DIR"
    sudo mv "$stale" "$BACKUP_DIR/"
  fi
done

if [ -f "$SO" ] && [ ! -f "$BACKUP_DIR/$(basename "$SO")" ]; then
  say "backing up $SO -> $BACKUP_DIR/$(basename "$SO")"
  sudo cp -a "$SO" "$BACKUP_DIR/"
fi

say "installing"
sudo install -m 755 -o root -g root build/libfprint/libfprint-2.so.2.0.0 "$SO"
if command -v restorecon >/dev/null; then
  sudo restorecon "$SO" || true
fi
sudo ldconfig
sudo systemctl restart fprintd || true

cat <<MSG

Done. Next:

  fprintd-enroll                    # enroll a finger
  fprintd-verify                    # test it
  fprintd-list "\$USER"             # list enrolled fingers

Roll back with:

  sudo install -m 755 $BACKUP_DIR/$(basename "$SO") $SO
  sudo restorecon $SO 2>/dev/null || true
  sudo ldconfig && sudo systemctl restart fprintd

Notes:

  * Fedora's fprintd is D-Bus activated; there is nothing to enable.
  * "Device disabled to prevent overheating" during long sessions is the
    libfprint thermal model, not a driver failure; wait a few minutes.
  * a dnf update of libfprint will replace the patched library. Re-run this
    script (it reuses the build) or copy
    build/libfprint/libfprint-2.so.2.0.0 into place again.

If the sensor still refuses the handshake, it carries a per-device key:
see docs/psk-write-findings.md.

MSG
