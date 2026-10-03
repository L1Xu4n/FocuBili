#!/usr/bin/env bash
set -euo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_CURRENT_DESKTOP=GNOME
openbox > /tmp/openbox.log 2>&1 &
dunst > /tmp/dunst.log 2>&1 &
printf '\n' | gnome-keyring-daemon --unlock --components=secrets >/tmp/keyring.env
mkdir -p build/linux-packages
python3 - <<'PY'
import os,subprocess,time
from pathlib import Path
out=Path('build/linux-packages')
p=subprocess.Popen(['build/linux/x64/release/bundle/focubili'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
with (out/'linux-runtime.log').open('w') as log:
 for line in p.stdout:
  print(line,end='',flush=True);log.write(line);log.flush()
  if 'LINUX_MINI_READY' in line:
   time.sleep(.6);subprocess.run(['scrot',str(out/'linux-mini-player.png')],check=True)
  if 'LINUX_CLIPBOARD_READY' in line:
   time.sleep(.5);subprocess.run(['scrot',str(out/'linux-video.png')],check=True)
code=p.wait()
assert code==0, f'Probe failed: {code}'
assert 'LINUX_RUNTIME_ALL_CHECKS_PASSED' in (out/'linux-runtime.log').read_text()
PY
