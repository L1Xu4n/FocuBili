#!/usr/bin/env bash
# Isolated CI simulator only. Verifies registration, a cancellation method reply
# and the probe-engine handshake, not removal of an existing OS pending request
# or a real-world background refresh opportunity.
set -euo pipefail
device="$1"
mkdir -p build/apple
run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
trap 'xcrun simctl terminate "$device" com.focubili.app >/dev/null 2>&1 || true' EXIT
flutter build ios --simulator --debug --target=tool/native_subscription_probe.dart --dart-define=NATIVE_SUBSCRIPTION_PROBE=true --dart-define="NATIVE_SUBSCRIPTION_PROBE_RUN_ID=$run_id"
xcrun simctl terminate "$device" com.focubili.app >/dev/null 2>&1 || true
xcrun simctl install "$device" build/ios/iphonesimulator/Runner.app
container="$(xcrun simctl get_app_container "$device" com.focubili.app data)"
report="$container/Documents/native-subscription-result.json"
rm -f "$report" "$report.tmp" build/apple/ios-subscription-result.json
xcrun simctl launch --terminate-running-process "$device" com.focubili.app
python3 - "$report" "$run_id" <<'PY'
import json, pathlib, sys, time
p = pathlib.Path(sys.argv[1])
end = time.monotonic() + 30
while time.monotonic() < end:
    if p.exists():
        try:
            result = json.loads(p.read_text())
        except (OSError, json.JSONDecodeError):
            time.sleep(.1)
            continue
        pathlib.Path('build/apple/ios-subscription-result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)
        assert result.get('runId') == sys.argv[2], result
        assert result.get('success') is True, result
        assert {'ios_launch_registration', 'ios_cancel_method_completed', 'ios_headless_engine_handshake'}.issubset(result.get('checks', [])), result
        print('IOS_SUBSCRIPTION_REGISTRATION_PASSED')
        break
    time.sleep(.1)
else:
    raise RuntimeError('iOS scheduler probe did not produce a fresh result')
PY
