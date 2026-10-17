"""Bounded desktop native callback probe. Use only in an isolated CI profile."""
import json
import os
from pathlib import Path
import subprocess
import sys

executable, output = sys.argv[1:3]
log = Path(output)
log.parent.mkdir(parents=True, exist_ok=True)
report_path = log.with_suffix('.json').resolve()
report_path.unlink(missing_ok=True)
options = {}
if sys.platform == 'win32':
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    options['startupinfo'] = startup
with log.open('w', encoding='utf-8') as stream:
    completed = subprocess.run([executable], stdout=stream,
                               stderr=subprocess.STDOUT, timeout=30,
                               env={**os.environ, 'FOCUBILI_NATIVE_SUBSCRIPTION_REPORT': str(report_path)},
                               **options)
text = log.read_text(encoding='utf-8', errors='replace')
print(text)
assert completed.returncode == 0, completed.returncode
assert report_path.exists(), 'A fresh native result is required'
report = json.loads(report_path.read_text(encoding='utf-8'))
assert report['success'] is True, report
assert {'native_timer_callback', 'native_generation_replacement',
        'native_timer_cancel'}.issubset(report['checks']), report
print('NATIVE_SUBSCRIPTION_DESKTOP_PASSED')
