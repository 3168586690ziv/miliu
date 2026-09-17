#!/usr/bin/env python3
"""Synchronization/rollback wrapper for build.sh, not a second build pipeline.

fcntl.flock is available on macOS. Ordinary and release builds share the lock
because both write generated version state and the source plist. Keep the lock
file inode permanent; unlinking it would allow two independent locks.

SIGINT/TERM are forwarded and rollback waits for the child process to stop.
SIGKILL/power loss cannot execute rollback; retained transaction evidence allows
manual recovery. Atomic replace protects each file, not the entire file group.
"""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile


class BuildFailed(Exception):
    def __init__(self, code):
        self.code = code


def atomic_restore(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextmanager
def transaction(root, extra_paths=()):
    root = Path(root).resolve()
    build = root / 'build'
    build.mkdir(parents=True, exist_ok=True)
    with (build / '.version-build.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        paths = [root / p for p in (
            'PROJECT_VERSION.json', 'src/Packaging/Info.plist',
            'build/generated/RDGeneratedVersion.h', 'build/generated/version.log',
            'build/generated/version.env')]
        paths.extend(Path(p) for p in extra_paths)
        evidence = Path(tempfile.mkdtemp(prefix='version-transaction-', dir=build))
        snapshots = {}
        for index, path in enumerate(dict.fromkeys(paths)):
            original = (path.read_bytes(), stat.S_IMODE(path.stat().st_mode)) if path.exists() else None
            snapshots[path] = original
            if original is not None:
                (evidence / f'{index}.before').write_bytes(original[0])
        (evidence / 'paths.txt').write_text('\n'.join(map(str, snapshots)) + '\n')
        try:
            yield
        except BaseException:
            for index, (path, original) in enumerate(snapshots.items()):
                if path.exists():
                    current = path.read_bytes()
                    (evidence / f'{index}.failed').write_bytes(current)
                    if original is not None and current == original[0]:
                        continue
                if original is None:
                    # Preserve newly generated failed state as evidence, not a success artifact.
                    if path.exists(): os.replace(path, evidence / f'{index}.new-failed')
                else:
                    atomic_restore(path, *original)
            (evidence / 'status.txt').write_text('FAILED: version state restored\n')
            raise
        else:
            (evidence / 'status.txt').write_text('SUCCESS\n')


def main():
    root = Path(__file__).resolve().parents[1]
    args = sys.argv[1:]
    outputs = [a for a in args if not a.startswith('-')]
    output = Path(outputs[-1]).absolute() if outputs else root / 'build/资源探测.app'
    try:
        with transaction(root, [output / 'Contents/Info.plist']):
            env = dict(os.environ, RD_BUILD_TRANSACTION_PID=str(os.getpid()))
            child = subprocess.Popen(['bash', str(root / 'scripts/build.sh'), *args],
                                     env=env, start_new_session=True)
            def forward(signum, frame):
                if child.poll() is None:
                    try: os.killpg(child.pid, signum)
                    except ProcessLookupError: pass
            previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM)}
            try:
                code = child.wait()
            finally:
                for sig, handler in previous.items(): signal.signal(sig, handler)
            if code:
                raise BuildFailed(code if code > 0 else 128 - code)
    except BuildFailed as error:
        print('FAIL: 构建失败，已恢复 JSON、源码 plist 与生成版本状态；失败证据保留在 build/version-transaction-*', file=sys.stderr)
        return error.code
    return 0


if __name__ == '__main__':
    sys.exit(main())
