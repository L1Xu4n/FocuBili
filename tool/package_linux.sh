#!/usr/bin/env bash
set -euo pipefail
version="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+)\+.*/\1/p' pubspec.yaml)"
test -n "$version"
bundle=build/linux/x64/release/bundle
out=build/linux-packages
test -x "$bundle/focubili"
mkdir -p "$out"
# Use a new staging directory on every invocation, so removed libraries never
# leak into a rebuilt DEB and an existing executable symlink cannot abort it.
root="$(mktemp -d "$out/.deb-staging.XXXXXX")"
trap 'rm -rf -- "$root"' EXIT
chmod 0755 "$root"
mkdir -p "$root/opt/focubili" "$root/usr/bin" "$root/usr/share/applications" "$root/usr/share/icons/hicolor/512x512/apps" "$root/DEBIAN"
cp -a "$bundle/." "$root/opt/focubili/"
ln -s /opt/focubili/focubili "$root/usr/bin/focubili"
cp linux/packaging/com.focubili.app.desktop "$root/usr/share/applications/"
cp assets/icon/focubili_icon.png "$root/usr/share/icons/hicolor/512x512/apps/com.focubili.app.png"
cat > "$root/DEBIAN/control" <<EOF
Package: focubili
Version: $version
Section: video
Priority: optional
Architecture: amd64
Maintainer: FocuBili Project
Depends: libgtk-3-0t64, libmpv2, libsecret-1-0, libjsoncpp25, libasound2t64, libwebkit2gtk-4.1-0, xdg-desktop-portal
Recommends: xdg-desktop-portal-gtk, gnome-keyring
Description: Focused Bilibili viewing and timestamp notes
 Linux desktop client with playback, offline cache and notes.
EOF
dpkg-deb --root-owner-group --build "$root" "$out/FocuBili-v$version-linux-amd64.deb"
tar -czf "$out/FocuBili-v$version-linux-x64.tar.gz" -C "$bundle" .
(cd "$out"; sha256sum ./*.deb ./*.tar.gz > SHA256SUMS.txt)
