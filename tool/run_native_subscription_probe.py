"""Bounded desktop native callback probe. Use only in an isolated CI profile."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


RESULT_MARKER = 'NATIVE_SUBSCRIPTION_RESULT '
REQUIRED_CHECKS = {'native_timer_callback', 'native_generation_replacement',
                   'native_timer_cancel'}


def validate_report(report, request_id, platform):
    expected_platform = {'darwin': 'macos', 'win32': 'windows', 'linux': 'linux'}
    if not isinstance(report, dict):
        raise RuntimeError('Native result must be a JSON object')
    if report.get('requestId') != request_id:
        raise RuntimeError('A result from this probe request is required')
    if report.get('platform') != expected_platform[platform]:
        raise RuntimeError('Native result platform does not match the runner')
    if report.get('success') is not True:
        raise RuntimeError(f'Native checks failed: {report}')
    checks = report.get('checks')
    if (not isinstance(checks, list)
            or any(not isinstance(check, str) for check in checks)
            or not REQUIRED_CHECKS.issubset(checks)):
        raise RuntimeError(f'Native timer checks are incomplete: {report}')
    return report


def read_stdout_report(text):
    # Never accept a stale file or choose one of multiple result lines.
    lines = [line for line in text.splitlines()
             if line.startswith(RESULT_MARKER.rstrip())]
    if len(lines) != 1 or not lines[0].startswith(RESULT_MARKER):
        raise RuntimeError('Exactly one native result line is required')
    try:
        return json.loads(lines[0][len(RESULT_MARKER):])
    except json.JSONDecodeError as error:
        raise RuntimeError('Malformed native result JSON') from error


def run_probe(executable, output, *, timeout=30, platform=None):
    platform = sys.platform if platform is None else platform
    if platform not in ('darwin', 'win32', 'linux'):
        raise RuntimeError(f'Unsupported desktop probe platform: {platform}')
    command = [executable] if isinstance(executable, str) else list(executable)
    log = Path(output)
    log.parent.mkdir(parents=True, exist_ok=True)
    report_path = log.with_suffix('.json').resolve()
    report_path.unlink(missing_ok=True)
    request_id = uuid.uuid4().hex
    env = {**os.environ, 'FOCUBILI_NATIVE_SUBSCRIPTION_REQUEST_ID': request_id}
    if platform == 'darwin':
        # A sandboxed app cannot write to the host's checkout. stdout is the
        # transport; only the host publishes the validated, fresh report.
        env.pop('FOCUBILI_NATIVE_SUBSCRIPTION_REPORT', None)
    else:
        env['FOCUBILI_NATIVE_SUBSCRIPTION_REPORT'] = str(report_path)
    options = {}
    if sys.platform == 'win32':
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        options['startupinfo'] = startup
    try:
        with log.open('w', encoding='utf-8') as stream:
            completed = subprocess.run(command, stdout=stream,
                                       stderr=subprocess.STDOUT, timeout=timeout,
                                       env=env, **options)
    finally:
        # Preserve diagnostics even when the child exceeds the time limit.
        text = log.read_text(encoding='utf-8', errors='replace')
        print(text, end='' if text.endswith('\n') else '\n')
    if completed.returncode != 0:
        raise RuntimeError(f'Native probe exited {completed.returncode}')
    if platform == 'darwin':
        report = read_stdout_report(text)
    else:
        if not report_path.exists():
            raise RuntimeError('A fresh native result file is required')
        report = json.loads(report_path.read_text(encoding='utf-8'))
    validate_report(report, request_id, platform)
    if platform == 'darwin':
        report_path.write_text(json.dumps(report, indent=2) + '\n',
                               encoding='utf-8')
    print('NATIVE_SUBSCRIPTION_DESKTOP_PASSED')
    return report


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: run_native_subscription_probe.py EXECUTABLE LOG')
    run_probe(*sys.argv[1:3])


if __name__ == '__main__':
    main()
