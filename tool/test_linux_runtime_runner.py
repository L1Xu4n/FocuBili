import unittest

from linux_runtime_runner import SUCCESS, validate_result


NORMAL = '[Inferior 1 (process 1234) exited normally]\n'


class RuntimeRunnerTest(unittest.TestCase):
    def test_complete_clean_exit(self):
        validate_result(0, SUCCESS + '\n' + NORMAL)

    def test_success_marker_cannot_hide_crash(self):
        for signal in ('SIGSEGV', 'SIGABRT'):
            for message in (f'Thread 1 received signal {signal}, fault.',
                            f'Program terminated with signal {signal}, fault.'):
                with self.subTest(message=message), self.assertRaises(RuntimeError):
                    validate_result(0, SUCCESS + '\n' + message + '\n' + NORMAL)

    def test_requires_clean_inferior_exit(self):
        for ending in ('', '[Inferior 1 (process 1234) exited with code 01]',
                       '[Inferior 1 (process 1234) killed]'):
            with self.subTest(ending=ending), self.assertRaises(RuntimeError):
                validate_result(0, SUCCESS + '\n' + ending)

    def test_requires_all_checks_and_debugger_success(self):
        with self.assertRaises(RuntimeError):
            validate_result(0, NORMAL)
        with self.assertRaises(RuntimeError):
            validate_result(1, SUCCESS + '\n' + NORMAL)


if __name__ == '__main__':
    unittest.main()
