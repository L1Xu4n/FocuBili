"""Run the native probe under GDB and fail closed on abnormal inferior exit."""
import re
import subprocess
from pathlib import Path


SUCCESS = 'LINUX_RUNTIME_ALL_CHECKS_PASSED'


def validate_result(code, transcript):
    if code != 0:
        raise RuntimeError(f'GDB failed: {code}')
    if re.search(r'(?:received|terminated with) signal SIG\w+', transcript):
        raise RuntimeError('Native probe received a fatal signal')
    if SUCCESS not in transcript:
        raise RuntimeError('Native probe did not complete all checks')
    if not re.search(r'^\[Inferior \d+ \(process \d+\) exited normally\]$',
                     transcript, re.MULTILINE):
        raise RuntimeError('Native probe did not exit normally')


def main():
    out = Path('build/linux-packages')
    out.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(
        ['gdb', '--batch', '-ex', 'handle SIGPIPE nostop noprint pass',
         '-ex', 'run', '-ex', 'thread apply all bt', '--args',
         'build/linux/x64/release/bundle/focubili'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    with (out / 'linux-runtime.log').open('w') as log:
        for line in process.stdout:
            print(line, end='', flush=True)
            log.write(line)
            log.flush()
            for marker, name in [('LINUX_MINI_READY', 'linux-mini-player.png'),
                                 ('LINUX_CLIPBOARD_READY', 'linux-video.png')]:
                if marker in line:
                    subprocess.run(['scrot', str(out / name)], check=True)
    validate_result(process.wait(), (out / 'linux-runtime.log').read_text())


if __name__ == '__main__':
    main()
