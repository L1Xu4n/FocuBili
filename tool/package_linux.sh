#!/usr/bin/env bash
set -euo pipefail
umask 022
version="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+)\+.*/\1/p' pubspec.yaml)"
if test -n "${FOCUBILI_PACKAGE_VERSION:-}"; then
  [[ "$FOCUBILI_PACKAGE_VERSION" =~ ^1\.9\.[0-9]+~beta\.[1-9][0-9]*\+[1-9][0-9]*$ ]]
  version="$FOCUBILI_PACKAGE_VERSION"
fi
test -n "$version"
bundle=build/linux/x64/release/bundle
out=build/linux-packages
test -x "$bundle/focubili"
# Include ABI minimums from every linked private library, not just the runner.
# Keep desktop services below: they have no ELF dependency to discover.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$out"
# Use a new staging directory on every invocation, so removed libraries never
# leak into a rebuilt DEB and an existing executable symlink cannot abort it.
root="$(mktemp -d "$out/.deb-staging.XXXXXX")"
trap 'rm -rf -- "$root"' EXIT
chmod 0755 "$root"
mkdir -p "$root/opt/focubili" "$root/usr/bin" "$root/usr/share/applications" "$root/usr/share/icons/hicolor/512x512/apps" "$root/DEBIAN"
cp -a "$bundle/." "$root/opt/focubili/"
ln -s /opt/focubili/focubili "$root/usr/bin/focubili"
install -m 0644 linux/packaging/com.focubili.app.desktop "$root/usr/share/applications/"
install -m 0644 assets/icon/focubili_icon.png "$root/usr/share/icons/hicolor/512x512/apps/com.focubili.app.png"
dependencies="$(python3 "$script_dir/linux_package_dependencies.py" "$root/opt/focubili")"
cat > "$root/DEBIAN/control" <<EOF
Package: focubili
Version: $version
Section: video
Priority: optional
Architecture: amd64
Maintainer: FocuBili Project
Depends: $dependencies, xdg-desktop-portal
Recommends: xdg-desktop-portal-gtk, gnome-keyring
Description: Focused Bilibili viewing and timestamp notes
 Linux desktop client with playback, offline cache and notes.
EOF
dpkg-deb --root-owner-group --build "$root" "$out/FocuBili-v$version-linux-amd64.deb"
tar -czf "$out/FocuBili-v$version-linux-x64.tar.gz" -C "$bundle" .
(cd "$out"; sha256sum ./*.deb ./*.tar.gz > SHA256SUMS.txt)
