#!/usr/bin/env bash
set -euo pipefail
export LIBGL_ALWAYS_SOFTWARE=1 XDG_CURRENT_DESKTOP=GNOME
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP
openbox >/tmp/focubili-launch-openbox.log 2>&1 &
dunst >/tmp/focubili-launch-dunst.log 2>&1 &
printf '\n' | gnome-keyring-daemon --unlock --components=secrets >/tmp/focubili-launch-keyring.env
mkdir -p build/linux-packages
build/linux/x64/release/bundle/focubili >build/linux-packages/linux-launch.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 12
kill -0 "$pid"
scrot build/linux-packages/linux-launch.png
# A second normal launch must activate the running instance and exit.
timeout 10s build/linux/x64/release/bundle/focubili >>build/linux-packages/linux-launch.log 2>&1
kill -0 "$pid"
printf 'LINUX_NORMAL_LAUNCH_AND_SINGLE_INSTANCE_PASSED\n'
