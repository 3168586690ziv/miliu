#!/usr/bin/env python3
"""Isolated regressions; never runs a build or modifies permanent version state."""
import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class SuiteRunnerTests(unittest.TestCase):
    def run_suites(self, names, scripts):
        with tempfile.TemporaryDirectory() as tmp:
            tests = Path(tmp) / 'tests/Tests'
            tests.mkdir(parents=True)
            shutil.copy2(ROOT / 'tests/Tests/run-suites.sh', tests)
            for name, body in scripts.items():
                (tests / (name + '.sh')).write_text(body)
            result = subprocess.run(['bash', str(tests / 'run-suites.sh'), *names],
                                    capture_output=True, text=True)
            logs = {p.stem: p.read_text() for p in (Path(tmp) / 'build/suite-logs').glob('*.log')}
            self.assertEqual(list(tests.glob('.sandbox-*')), [])
            return result, logs

    def test_no_arguments(self):
        result, logs = self.run_suites([], {})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('ALL SUITES PASSED', result.stdout)
        self.assertFalse(logs)

    def test_missing(self):
        result, _ = self.run_suites(['missing'], {})
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_failed(self):
        result, _ = self.run_suites(['bad'], {'bad': 'echo FAIL; exit 9\n'})
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_mixed_continues_and_lists_failures(self):
        result, logs = self.run_suites(['bad', 'missing', 'ok'],
                                     {'bad': 'echo FAIL; exit 9\n', 'ok': 'echo PASS; exit 0\n'})
        self.assertIn('ok', logs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('FAILED SUITES: bad missing', result.stdout)

    def test_all_success_including_silent_suite(self):
        result, _ = self.run_suites(['ok', 'silent'],
                                   {'ok': 'echo PASS; exit 0\n', 'silent': 'exit 0\n'})
        self.assertEqual(result.returncode, 0, result.stdout)


class TransactionTests(unittest.TestCase):
    def module(self):
        spec = importlib.util.spec_from_file_location('transaction', ROOT / 'scripts/build-transaction.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_failure_restores_json_plist_and_generated_state(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            paths = ['PROJECT_VERSION.json', 'src/Packaging/Info.plist',
                     'build/generated/RDGeneratedVersion.h', 'build/generated/version.log',
                     'build/generated/version.env']
            for rel in paths:
                p = root / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'original\n')
            with self.assertRaises(RuntimeError):
                with module.transaction(root):
                    for rel in paths: (root / rel).write_bytes(b'changed\n')
                    raise RuntimeError('injected signing failure')
            for rel in paths: self.assertEqual((root / rel).read_bytes(), b'original\n')

    def test_concurrent_failure_cannot_rollback_success(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'PROJECT_VERSION.json').write_text('old')
            worker = '''import importlib.util, pathlib, sys, time
spec = importlib.util.spec_from_file_location('transaction', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = pathlib.Path(sys.argv[2])
try:
    with m.transaction(r):
        assert not (r / 'busy').exists(), 'overlapping build transactions'
        (r / 'busy').write_text('yes')
        if sys.argv[3] == 'success':
            (r / 'entered').write_text('yes'); time.sleep(0.25)
            (r / 'PROJECT_VERSION.json').write_text('success')
        else:
            assert (r / 'PROJECT_VERSION.json').read_text() == 'success'
            (r / 'PROJECT_VERSION.json').write_text('failed')
        (r / 'busy').unlink()
        if sys.argv[3] != 'success': raise RuntimeError('injected failure')
except RuntimeError:
    if sys.argv[3] == 'success': raise
'''
            import sys, time
            args = [sys.executable, '-c', worker, str(ROOT / 'scripts/build-transaction.py'), tmp]
            first = subprocess.Popen(args + ['success'])
            try:
                deadline = time.monotonic() + 5
                while not (root / 'entered').exists() and time.monotonic() < deadline:
                    time.sleep(0.005)
                self.assertTrue((root / 'entered').exists())
                second = subprocess.run(args + ['fail'], timeout=10)
                self.assertEqual(first.wait(timeout=10), 0)
                self.assertEqual(second.returncode, 0)
                self.assertEqual((root / 'PROJECT_VERSION.json').read_text(), 'success')
            finally:
                if first.poll() is None: first.terminate(); first.wait()


class DigestTests(unittest.TestCase):
    def test_walk_order_and_global_path_order(self):
        spec = importlib.util.spec_from_file_location('digest', ROOT / 'scripts/release-digest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / 'src'
            files = {'z.m': b'z\n', 'z/q.m': b'q\n', 'a/z.m': b'a\n', 'a/b/c.h': b'b\n'}
            for rel, content in files.items():
                p = src / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(content)
            module.ROOT, module.SRC = tmp, str(src)
            walk = list(os.walk(src))
            outputs = []
            for rows in (walk, list(reversed(walk))):
                with patch.object(module.os, 'walk', return_value=iter(rows)), contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(module.main(), 0)
                outputs.append(out.getvalue().strip())
            self.assertEqual(outputs[0], outputs[1])
            parts = ['src/' + rel + ' ' + hashlib.sha256(content).hexdigest()
                     for rel, content in sorted(files.items())]
            self.assertEqual(outputs[0], hashlib.sha256('\n'.join(parts).encode()).hexdigest())


if __name__ == '__main__':
    unittest.main(verbosity=2)
