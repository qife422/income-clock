#!/usr/bin/env python3
"""Prepare by default; --run launches only the pinned RESUME005 isolated Debug app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

PROJECT = Path(__file__).resolve().parent.parent
RUN = Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001')
BUNDLE = RUN / 'DerivedData/Build/Products/Debug/IncomeClock.app'
EXECUTABLE = BUNDLE / 'Contents/MacOS/IncomeClock'
UIDATA = RUN / 'UIData'
SOURCE = PROJECT / 'STAGE9_RESUME005_SOURCE.json'
SIGNATURE = PROJECT / 'STAGE9_RESUME005_SIGNATURE.json'
SOURCE_SHA = '4c9cf77b34c6a4619c5096aa66bd64b35ea8680c7911e3fd8566cff6b31d1d97'
SIGNATURE_SHA = 'a816fcf03e00500449e0a7dd9afc1589415389e327a7e348f16beaf2f92cc7e7'
DYLIB_SHA = '92faa1c3b275528ea31339700ddc096791a7e98d147c7a8faaf7e57a1399ccdc'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify():
    require(digest(SOURCE) == SOURCE_SHA, 'Frozen source manifest changed')
    require(digest(SIGNATURE) == SIGNATURE_SHA, 'Frozen signature record changed')
    source = json.loads(SOURCE.read_text())
    require(len(source) == 93, 'Expected the original 93-file source manifest')
    for relative, expected in source.items():
        path = PROJECT / relative
        require(path.resolve().is_relative_to(PROJECT), 'Source path escapes project')
        require(digest(path) == expected, 'Source drift: ' + relative)
    record = next(r for r in json.loads(SIGNATURE.read_text()) if r['path'] == str(BUNDLE))
    require(digest(EXECUTABLE) == record['binary_sha256'], 'Executable differs from signature record')
    require(digest(BUNDLE / 'Contents/MacOS/IncomeClock.debug.dylib') == DYLIB_SHA,
            'Debug implementation dylib differs from prepared RESUME005 build')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(BUNDLE)],
                   check=True, capture_output=True, timeout=30)
    return {'source_files': len(source), 'source_manifest_sha256': SOURCE_SHA,
            'executable_sha256': record['binary_sha256'], 'debug_dylib_sha256': DYLIB_SHA,
            'codesign': 'verified-deep-strict'}


def stop_signal(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--prepare-only', action='store_true', help='Read-only validation; default')
    mode.add_argument('--run', action='store_true', help='Launch and supervise this one pinned child')
    args = parser.parse_args()
    checks = verify()
    require(UIDATA.is_dir(), 'Original UIData root is missing; do not create another root')
    root = UIDATA / ('NativeProbe-' + str(uuid.uuid4()))
    nonce = str(uuid.uuid4())
    command = [str(EXECUTABLE), '--debug-now-ms', '1788836400000', '--debug-time-rate', '0']
    plan = {'state': 'prepared-not-launched', 'bundle': str(BUNDLE), 'executable': str(EXECUTABLE),
            'root': str(root), 'nonce': nonce, 'command': command, 'checks': checks,
            'isolation_protocol': 'marker-missing explicit-root branch; ui-isolation-receipt.json'}
    if not args.run:
        print(json.dumps(plan, ensure_ascii=False), flush=True)
        return 0
    # No marker/claim is written. The marker route requires an IncomeClock app
    # parent, so a Python supervisor must use the existing explicit-root branch.
    # An unexpected marker can cause rejection or a mismatched receipt; neither
    # may be treated as ready and no marker is removed by this script.
    root.mkdir(mode=0o700)  # Fresh UUID, exclusive; no seed or real user data.
    require(root.resolve().parent == UIDATA.resolve(), 'Root is outside original UIData')
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('INCOMECLOCK_', 'XCTest', 'DYLD_', 'XCInject'))}
    env['INCOMECLOCK_TEST_ROOT'] = str(root)
    env['INCOMECLOCK_UI_ISOLATION_NONCE'] = nonce
    child = None
    result = dict(plan)
    log = None
    old_handlers = {}
    try:
        for sig in (signal.SIGINT, signal.SIGTERM):
            old_handlers[sig] = signal.signal(sig, stop_signal)
        log = (root / 'child.log').open('xb')
        child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        result.update(state='launched-awaiting-receipt', pid=child.pid)
        receipt_path = root / 'ui-isolation-receipt.json'
        deadline = time.monotonic() + 20
        while not receipt_path.exists():
            require(child.poll() is None, 'Child exited before isolation receipt')
            require(time.monotonic() < deadline, 'Isolation receipt timed out')
            time.sleep(0.1)
        receipt = json.loads(receipt_path.read_text())
        require(receipt['pid'] == child.pid, 'Receipt PID mismatch')
        require(receipt['nonce'] == nonce, 'Receipt nonce mismatch')
        require(Path(receipt['root']).resolve() == root.resolve(), 'Receipt root mismatch')
        require(Path(receipt['bundle']).resolve() == BUNDLE.resolve(), 'Receipt bundle mismatch')
        require(Path(receipt['arguments'][0]).resolve() == EXECUTABLE.resolve(), 'Receipt executable mismatch')
        require(receipt['arguments'][1:] == command[1:], 'Receipt arguments mismatch')
        result['checks'] = verify()
        require(child.poll() is None, 'Child exited during identity verification')
        result.update(state='ready', receipt=receipt)
        (root / 'supervisor.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False), flush=True)
        # Keep this Python process running while CUA attaches by exact full path.
        # No launch-by-name, CUA calls, system preference writes or other PID kills.
        while child.poll() is None:
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        result.update(state='child-exited', exit_code=child.returncode)
        return child.returncode or 0
    except KeyboardInterrupt:
        result['state'] = 'supervisor-interrupted'
        return 130
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        if child is not None:
            result['exit_code'] = child.returncode
        if log is not None:
            log.close()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        result['disposition'] = 'Retained isolated UUID directory; no deletion or cleanup performed'
        (root / 'supervisor-final.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('NOT READY: ' + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
