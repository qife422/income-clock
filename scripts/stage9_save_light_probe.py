#!/usr/bin/env python3
"""Prepare by default; --run launches only the pinned current isolated Debug app for a light Settings observation."""
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
BUNDLE = RUN / 'DerivedData/Resume011Fresh/Build/Products/Debug/IncomeClock.app'
EXECUTABLE = BUNDLE / 'Contents/MacOS/IncomeClock'
UIDATA = RUN / 'UIData'
BINDING = PROJECT / 'STAGE9_SAVE_FOCUS_TEST_NATIVE_BINDING.json'
BINDING_SHA = '2016f0c980955dc5a62277b1534a0e6b772f1ba56b8b7dbac7f079d460e934ee'
BUDGET = PROJECT / 'STAGE9_SAVE_LIGHT_PROBE_BUDGET.json'
BUDGET_SHA = '8b878ab8d9f9f074f1bcb153d46014ae69395c2b2a826d0549739ec47c3e08d3'
from stage9_run_monitored import sample, crossed, read_budget



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
    require(digest(BINDING) == BINDING_SHA, 'Frozen existing native binding changed')
    bound = json.loads(BINDING.read_text())
    source_path = PROJECT / bound['source_manifest']
    require(digest(source_path) == bound['source_manifest_sha256'], 'Source manifest changed')
    source = json.loads(source_path.read_text())
    require(len(source) == 93, 'Expected 93 source inputs')
    for relative, expected in source.items():
        path = PROJECT / relative
        require(path.resolve().is_relative_to(PROJECT), 'Source escapes project')
        require(digest(path) == expected, 'Source drift: ' + relative)
    for path, expected in bound['binary_sha256'].items():
        require(digest(Path(path)) == expected, 'Binary drift: ' + path)
    for relative, expected in bound['wrapper_sha256'].items():
        require(digest(PROJECT / relative) == expected, 'Wrapper drift: ' + relative)
    require(digest(PROJECT / bound['signature_receipt']) == bound['signature_receipt_sha256'], 'Signature receipt drift')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(BUNDLE)],
                   check=True, capture_output=True, timeout=30)
    return {'source_files': 93, 'binaries': 5, 'wrappers': 3,
            'binding_sha256': BINDING_SHA, 'codesign': 'verified-deep-strict'}


def stop_signal(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--prepare-only', action='store_true', help='Read-only validation; default')
    mode.add_argument('--run', action='store_true', help='Launch and supervise this one pinned child')
    args = parser.parse_args()
    checks = verify()
    require(digest(BUDGET) == BUDGET_SHA, 'Frozen budget changed')
    budget = read_budget(BUDGET)
    capacity = sample()
    require(not crossed(capacity, budget), 'Artifact hard cap reached')
    require(max(capacity['combined_allocated'], capacity['combined_logical']) < budget['projected_peak_bytes'], 'No observation forecast headroom')
    require(UIDATA.is_dir(), 'Original UIData root is missing; do not create another root')
    root = UIDATA / ('SaveLightProbe-' + str(uuid.uuid4()))
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
    live = subprocess.run(['/usr/bin/pgrep', '-x', 'IncomeClock'], capture_output=True, text=True, timeout=5)
    require(live.returncode == 1, 'Existing IncomeClock process; refuse launch')
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
        observation_deadline = time.monotonic() + 480
        next_capacity_check = 0
        peak = max(capacity['combined_allocated'], capacity['combined_logical'])
        while child.poll() is None:
            require(time.monotonic() < observation_deadline, '480-second observation deadline reached')
            if time.monotonic() >= next_capacity_check:
                capacity = sample()
                peak = max(peak, capacity['combined_allocated'], capacity['combined_logical'])
                result['sampled_peak_bytes'] = peak
                require(not crossed(capacity, budget), 'Artifact hard cap crossed')
                require(peak <= budget['projected_peak_bytes'], '80MiB observation forecast crossed')
                next_capacity_check = time.monotonic() + 5
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        result.update(state='child-exited', exit_code=child.returncode)
        require(child.returncode == 0, 'Owned child did not exit cleanly')
        completion_path = root / 'observation-complete.json'
        require(completion_path.is_file() and completion_path.stat().st_size <= 16384,
                'No bounded observation completion manifest; process exit alone is insufficient')
        completion = json.loads(completion_path.read_text())
        require(completion.get('scope') == 'light-save-outline-observation', 'Wrong completion scope')
        require(completion.get('pid') == child.pid and completion.get('nonce') == nonce,
                'Completion does not bind the verified child')
        artifacts = completion.get('artifacts', [])
        require(len(artifacts) == 4 and {a['path'] for a in artifacts} ==
                {'light-save-enabled.png', 'light-save-enabled-ax.txt',
                 'light-save-committed.png', 'light-save-committed-ax.txt'},
                'Need both unmodified PNG/AX pairs')
        for artifact in artifacts:
            capture = root / artifact['path']
            require(capture.resolve().parent == root.resolve() and capture.is_file(), 'Capture escapes root or missing')
            require(0 < capture.stat().st_size <= 5 * 1024 * 1024 and digest(capture) == artifact['sha256'],
                    'Capture size/hash mismatch')
            if capture.suffix == '.png':
                with capture.open('rb') as handle:
                    require(handle.read(8) == b'\x89PNG\r\n\x1a\n', 'Capture is not original PNG bytes')
        result.update(state='completed-captures-present-awaiting-independent-review',
                      completion_manifest_sha256=digest(completion_path))
        return 0
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
