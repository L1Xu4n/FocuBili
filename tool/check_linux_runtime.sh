#!/usr/bin/env bash
set -euo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_CURRENT_DESKTOP=GNOME
# The bus starts before Xvfb; pass its display to D-Bus-activated portal services.
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP
openbox > /tmp/openbox.log 2>&1 &
dunst > /tmp/dunst.log 2>&1 &
printf '\n' | gnome-keyring-daemon --unlock --components=secrets >/tmp/keyring.env
mkdir -p build/linux-packages
# Keep debugger parsing independently testable; GDB can exit 0 after a crash.
LC_ALL=C python3 tool/linux_runtime_runner.py
