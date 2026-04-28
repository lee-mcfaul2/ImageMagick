#!/usr/bin/env bash
#
# slsa-autotools linux binary hook for ImageMagick.
#
# Builds an x86_64 AppImage of ImageMagick using linuxdeploy
# (modern AppImage builder, no host-glibc check, ships pinnable
# tagged releases).
#
# Runs from inside the distdir produced by `make distdir`.
# Output: ImageMagick-${VERSION}-x86_64.AppImage in the distdir.
# The release.yml caller globs *-x86_64.AppImage and copies into
# the artifact upload set.

set -euo pipefail

DISTDIR_BUILD="$(pwd)"

LINUXDEPLOY_URL='https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage'
LINUXDEPLOY_SHA256='c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d'

# 1. Pin and stage linuxdeploy. --appimage-extract avoids needing
#    FUSE in the container; the extracted AppRun + bundled
#    appimagetool plugin run from squashfs-root.
mkdir -p /tmp/linuxdeploy
cd /tmp/linuxdeploy
curl -fsSL "${LINUXDEPLOY_URL}" -o linuxdeploy.AppImage
echo "${LINUXDEPLOY_SHA256}  linuxdeploy.AppImage" | sha256sum -c -
chmod +x linuxdeploy.AppImage
./linuxdeploy.AppImage --appimage-extract >/dev/null
LINUXDEPLOY_BIN=/tmp/linuxdeploy/squashfs-root/AppRun

# 2. Configure + build + install to a staging DESTDIR. --prefix=/usr
#    is the AppImage convention so binaries land at appdir/usr/bin
#    once DESTDIR is stripped. Flag set matches the project's existing
#    linux_app_image CI job.
cd "${DISTDIR_BUILD}"
APPDIR="${DISTDIR_BUILD}/appdir"
rm -rf "${APPDIR}"
mkdir -p "${APPDIR}"
./configure \
  --quiet \
  --prefix=/usr \
  --with-quantum-depth=16 \
  --without-magick-plus-plus \
  --without-perl
make
make install DESTDIR="${APPDIR}"

# 3. Stage desktop file + icon. Neither is in EXTRA_DIST, so they
#    don't survive `make distdir` — reach back to the original
#    checkout via ${GITHUB_WORKSPACE}.
SRC_APPIMAGE_DIR="${GITHUB_WORKSPACE}/app-image"
mkdir -p "${APPDIR}/usr/share/applications"
cp "${SRC_APPIMAGE_DIR}/imagemagick.desktop" "${APPDIR}/usr/share/applications/"
mkdir -p "${APPDIR}/usr/share/icons/hicolor/128x128/apps"
cp "${SRC_APPIMAGE_DIR}/icon.png" "${APPDIR}/usr/share/icons/hicolor/128x128/apps/imagemagick.png"

# 4. Drop custom AppRun BEFORE linuxdeploy runs. linuxdeploy detects
#    an existing AppDir/AppRun and skips its default-AppRun generation
#    step. The project-shipped AppRun handles MAGICK_HOME / module
#    path setup + multi-binary symlink dispatch.
cp "${SRC_APPIMAGE_DIR}/AppRun" "${APPDIR}/AppRun"
chmod +x "${APPDIR}/AppRun"

# 5. Bundle dependent libs + create AppImage.
#    NO_STRIP=1: prevents linuxdeploy from running strip on bundled
#      binaries — strip's output can vary between runs.
#    LD_LIBRARY_PATH includes APPDIR's lib dir: linuxdeploy walks
#      ELF NEEDED via ld.so, which only checks default search paths.
#      libMagickCore-*.so was just installed to APPDIR/usr/lib and
#      isn't on a system path, so without this hint linuxdeploy
#      errors "Could not find dependency: libMagickCore-...so.10".
LD_LIBRARY_PATH="${APPDIR}/usr/lib:${LD_LIBRARY_PATH:-}" \
NO_STRIP=1 \
  "${LINUXDEPLOY_BIN}" \
    --appdir "${APPDIR}" \
    --desktop-file "${APPDIR}/usr/share/applications/imagemagick.desktop" \
    --icon-file "${APPDIR}/usr/share/icons/hicolor/128x128/apps/imagemagick.png" \
    --output appimage

# 6. linuxdeploy emits the AppImage with a Name-derived filename.
#    Rename to include the project version so release.yml's glob
#    matches the canonical *-x86_64.AppImage shape.
VERSION=$(awk -F' *= *' '$1 == "VERSION" {print $2; exit}' "${DISTDIR_BUILD}/Makefile")
[ -n "${VERSION}" ] || { echo "ERROR: could not derive VERSION from distdir Makefile"; exit 1; }
for src in ImageMagick-x86_64.AppImage ImageMagick-*-x86_64.AppImage; do
  [ -f "${src}" ] || continue
  case "${src}" in
    "ImageMagick-${VERSION}-x86_64.AppImage") ;;
    *) mv "${src}" "ImageMagick-${VERSION}-x86_64.AppImage" ;;
  esac
  break
done
ls -la "${DISTDIR_BUILD}"/ImageMagick-*-x86_64.AppImage
