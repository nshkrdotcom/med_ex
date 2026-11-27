"""Exercise the actual qualification corpus preflight before starting Mix."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'build_support/receipt_fixture.sh'
CORPUS = ROOT / 'core/med_core/test/fixtures/receipt_vectors_v2.json'


class ReceiptFixtureTest(unittest.TestCase):
    def invoke(self, path, override=None):
        env = dict(os.environ)
        env.pop('MEDEX_RECEIPT_VECTORS', None)
        if override is not None:
            env['MEDEX_RECEIPT_VECTORS'] = str(override)
        return subprocess.run(['bash', '-c',
            'source "$1"; medex_receipt_fixture "$2" || exit $?; printf "%s" "$MEDEX_RECEIPT_VECTORS"',
            'fixture', str(HELPER), str(path)], env=env, text=True,
            capture_output=True, timeout=5)

    def test_canonical_corpus_and_override_are_verified(self):
        for default, override in [(CORPUS, None), ('/missing', CORPUS)]:
            result = self.invoke(default, override)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(result.stdout), CORPUS)

    def test_missing_corrupt_and_symlink_inputs_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bad = root / 'bad.json'
            bad.write_bytes(CORPUS.read_bytes() + b'\n')
            link = root / 'link.json'
            link.symlink_to(CORPUS)
            for path in [root / 'missing', bad, link]:
                result = self.invoke(path)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
                self.assertIn('Receipt fixture unavailable', result.stderr)


if __name__ == '__main__':
    unittest.main()
