"""Real child-process tests for the desktop probe's report transport."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from run_native_subscription_probe import run_probe


CHILD = r'''
import json
import os
from pathlib import Path
import sys
import time

scenario, platform = sys.argv[1:3]
report = {
    'success': True,
    'platform': platform,
    'requestId': os.environ['FOCUBILI_NATIVE_SUBSCRIPTION_REQUEST_ID'],
    'checks': ['native_timer_callback', 'native_generation_replacement',
               'native_timer_cancel'],
}
if scenario == 'wrong_nonce':
    report['requestId'] = 'a-previous-request'
elif scenario == 'wrong_platform':
    report['platform'] = 'ios'
elif scenario == 'failed':
    report['success'] = False
    report['error'] = 'Cancelled timer kept ticking'
elif scenario == 'missing_check':
    report['checks'].remove('native_timer_cancel')
elif scenario == 'bad_checks':
    report['checks'] = 'native_timer_callback native_generation_replacement native_timer_cancel'
elif scenario == 'truthy_success':
    report['success'] = 1
elif scenario == 'not_object':
    report = []

if scenario == 'missing':
    print('ordinary native diagnostic', flush=True)
elif scenario == 'malformed':
    print('NATIVE_SUBSCRIPTION_RESULT {not JSON}', flush=True)
elif scenario == 'bare_marker':
    print('NATIVE_SUBSCRIPTION_RESULT', flush=True)
elif scenario == 'file':
    Path(os.environ['FOCUBILI_NATIVE_SUBSCRIPTION_REPORT']).write_text(
        json.dumps(report), encoding='utf-8')
    print('ordinary native diagnostic', flush=True)
else:
    assert 'FOCUBILI_NATIVE_SUBSCRIPTION_REPORT' not in os.environ
    print('ordinary native diagnostic', flush=True)
    line = 'NATIVE_SUBSCRIPTION_RESULT ' + json.dumps(report)
    print(line, flush=True)
    if scenario == 'duplicate':
        print(line, flush=True)
    if scenario == 'crash':
        sys.exit(7)
    if scenario == 'timeout':
        time.sleep(10)
'''


class NativeSubscriptionProbeTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.log = Path(self.folder.name) / 'native-subscription.log'
        self.report_path = self.log.with_suffix('.json')

    def run_child(self, scenario='fresh', platform='darwin', timeout=5):
        native_platform = {'darwin': 'macos', 'win32': 'windows', 'linux': 'linux'}
        command = [sys.executable, '-c', CHILD, scenario, native_platform[platform]]
        with contextlib.redirect_stdout(io.StringIO()):
            return run_probe(command, self.log, timeout=timeout, platform=platform)

    def reject(self, scenario):
        with self.assertRaises(RuntimeError):
            self.run_child(scenario)
        self.assertFalse(self.report_path.exists())
        self.assertTrue(self.log.exists())

    def test_macos_host_writes_fresh_stdout_result(self):
        self.log.write_text('old log', encoding='utf-8')
        self.report_path.write_text('{"success": true}', encoding='utf-8')
        first = self.run_child()
        self.assertEqual(json.loads(self.report_path.read_text()), first)
        self.assertEqual(first['platform'], 'macos')
        self.assertEqual(len(first['requestId']), 32)
        self.assertNotIn('old log', self.log.read_text())
        second = self.run_child()
        self.assertNotEqual(first['requestId'], second['requestId'])
        self.assertEqual(json.loads(self.report_path.read_text()), second)

    def test_missing_result_cannot_reuse_old_success(self):
        self.report_path.write_text('{"success": true}', encoding='utf-8')
        self.reject('missing')

    def test_malformed_json_is_rejected(self):
        self.reject('malformed')

    def test_bare_marker_is_rejected(self):
        self.reject('bare_marker')

    def test_duplicate_results_are_rejected(self):
        self.reject('duplicate')

    def test_previous_request_result_is_rejected(self):
        self.reject('wrong_nonce')

    def test_wrong_platform_is_rejected(self):
        self.reject('wrong_platform')

    def test_failed_timer_assertion_is_rejected_even_with_clean_exit(self):
        self.reject('failed')

    def test_nonzero_exit_cannot_be_hidden_by_success_result(self):
        self.reject('crash')

    def test_incomplete_timer_checks_are_rejected(self):
        self.reject('missing_check')

    def test_non_list_checks_are_rejected(self):
        self.reject('bad_checks')

    def test_numeric_success_is_rejected(self):
        self.reject('truthy_success')

    def test_non_object_json_is_rejected(self):
        self.reject('not_object')

    def test_timeout_after_success_output_cannot_publish_result(self):
        self.report_path.write_text('{"success": true}', encoding='utf-8')
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_child('timeout', timeout=1)
        self.assertFalse(self.report_path.exists())
        self.assertIn('NATIVE_SUBSCRIPTION_RESULT ', self.log.read_text())

    def test_windows_and_linux_keep_file_report_transport(self):
        for platform in ('win32', 'linux'):
            with self.subTest(platform=platform):
                report = self.run_child('file', platform=platform)
                self.assertEqual(json.loads(self.report_path.read_text()), report)
                self.assertNotIn('NATIVE_SUBSCRIPTION_RESULT', self.log.read_text())

    def test_file_platform_cannot_reuse_old_result(self):
        for platform in ('win32', 'linux'):
            with self.subTest(platform=platform):
                self.report_path.write_text('{"success": true}', encoding='utf-8')
                with self.assertRaises(RuntimeError):
                    self.run_child('missing', platform=platform)
                self.assertFalse(self.report_path.exists())


if __name__ == '__main__':
    unittest.main()
