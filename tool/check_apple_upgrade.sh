#!/usr/bin/env bash
# CI-only replacement-install test; runs after normal app artifacts are packaged.
set -euo pipefail
platform="$1"
device="${2:-}"
mkdir -p build/apple
for phase in seed verify; do
  if [ "$phase" = seed ]; then number=900001; else number=900002; fi
  if [ "$platform" = ios ]; then
    flutter build ios --simulator --debug --target=tool/apple_upgrade_probe.dart --dart-define="UPGRADE_PHASE=$phase" --build-number="$number"
    # Never uninstall: the point is to exercise replacement installation.
    xcrun simctl install "$device" build/ios/iphonesimulator/Runner.app
    container="$(xcrun simctl get_app_container "$device" com.focubili.app data)"
    report="$container/Documents/apple-upgrade-report.json"
    rm -f "$report"
    xcrun simctl launch --terminate-running-process "$device" com.focubili.app
    python3 - "$report" "$phase" <<'PY'
import json, pathlib, sys, time
p, phase = pathlib.Path(sys.argv[1]), sys.argv[2]
end = time.monotonic() + 60
while time.monotonic() < end:
    if p.exists():
        try:
            value = json.loads(p.read_text())
        except (json.JSONDecodeError, OSError):
            time.sleep(.2)
            continue
        assert value.get('phase') == phase and value.get('success') is True, value
        print('APPLE_UPGRADE_' + phase.upper() + '_PASSED')
        break
    time.sleep(.2)
else:
    raise RuntimeError('No upgrade report: ' + str(p))
PY
    cp "$report" "build/apple/ios-upgrade-$phase.json"
  elif [ "$platform" = macos ]; then
    flutter build macos --release --target=tool/apple_upgrade_probe.dart --dart-define="UPGRADE_PHASE=$phase" --build-number="$number"
    python3 - "$phase" <<'PY'
import pathlib, subprocess, sys
phase = sys.argv[1]
r = subprocess.run(['build/macos/Build/Products/Release/FocuBili.app/Contents/MacOS/FocuBili'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
pathlib.Path('build/apple/macos-upgrade-' + phase + '.log').write_text(r.stdout)
print(r.stdout)
assert r.returncode == 0 and 'APPLE_UPGRADE_' + phase.upper() + '_PASSED' in r.stdout
PY
  else
    echo 'Unknown platform' >&2; exit 2
  fi
done
