"""Real timeout/cancellation tests for the qualification subprocess owner."""
from pathlib import Path
import subprocess
import time
import unittest

WRAPPER = Path(__file__).resolve().parents[1] / 'build_support' / 'qualification_command.sh'


class QualificationCommandTest(unittest.TestCase):
    def run_gate(self, seconds, *command, cancel=False):
        started = time.monotonic()
        with subprocess.Popen(['bash', str(WRAPPER), str(seconds), *command],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) as process:
            if cancel:
                process.stdin.close()
            status = process.wait(timeout=5)
            stdout, stderr = process.stdout.read(), process.stderr.read()
            if not cancel:
                process.stdin.close()
        return status, stdout, stderr, time.monotonic() - started

    def test_success_and_exit_code_are_preserved(self):
        status, stdout, _, _ = self.run_gate(2, 'sh', '-c', 'printf qualified; exit 7')
        self.assertEqual((status, stdout), (7, 'qualified'))

    def test_actual_deadline_terminates_the_gate(self):
        status, _, _, elapsed = self.run_gate(1, 'sleep', '30')
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 4)

    def test_owner_eof_cancels_without_waiting_for_wall_budget(self):
        status, _, _, elapsed = self.run_gate(30, 'sleep', '30', cancel=True)
        self.assertNotEqual(status, 0)
        self.assertLess(elapsed, 4)

    def test_invalid_budget_refuses_before_command(self):
        for budget in ('0', '5401', 'forever', '1;touch'):
            status, stdout, _, _ = self.run_gate(budget, 'printf', 'unexpected')
            self.assertEqual(status, 2)
            self.assertEqual(stdout, '')


if __name__ == '__main__':
    unittest.main()
