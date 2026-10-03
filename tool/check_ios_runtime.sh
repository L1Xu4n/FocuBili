#!/usr/bin/env bash
set -euo pipefail
device="$1"
mkdir -p build/apple
run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
trap 'xcrun simctl terminate "$device" com.focubili.app >/dev/null 2>&1 || true' EXIT
flutter build ios --simulator --debug --target=tool/ios_runtime_probe.dart --dart-define="IOS_PROBE_RUN_ID=$run_id"
xcrun simctl terminate "$device" com.focubili.app >/dev/null 2>&1 || true
xcrun simctl install "$device" build/ios/iphonesimulator/Runner.app
container="$(xcrun simctl get_app_container "$device" com.focubili.app data)"
report="$container/Documents/ios-runtime-result.json"
rm -f "$report" "$report.tmp" build/apple/ios-runtime-result.json
xcrun simctl launch --terminate-running-process "$device" com.focubili.app
python3 - "$report" "$run_id" <<'PY'
import json,pathlib,sys,time
p=pathlib.Path(sys.argv[1]);end=time.monotonic()+180
required={'native_decode','pause_seek_rate','preferences','cookie_bridge','webview_provider','notification_bridge'}
while time.monotonic()<end:
    if p.exists():
        try: result=json.loads(p.read_text())
        except (OSError,json.JSONDecodeError): time.sleep(.2);continue
        pathlib.Path('build/apple/ios-runtime-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
        print(json.dumps(result,ensure_ascii=False),flush=True)
        assert result.get('runId') == sys.argv[2], result
        assert result.get('success') is True, result
        assert required.issubset(result.get('checks',[])), result
        assert {'pip_frame_and_status','pip_runtime_unsupported'}.intersection(result['checks']), result
        print('IOS_RUNTIME_ALL_CHECKS_PASSED')
        break
    time.sleep(.2)
else: raise RuntimeError('Native iOS probe did not report within 180 seconds')
PY
