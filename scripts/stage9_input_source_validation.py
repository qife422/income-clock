#!/usr/bin/env python3
"""Temporarily select an explicit existing ASCII layout, supervise an authorized Stage9 run, restore exact ID.

No helper compilation, source enable/install/remove, or direct preference write.
The original capture is exclusive and fsynced before any selection is attempted.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from stage9_run_monitored import LIMITS, crossed, read_budget, sample

PROJECT = Path(__file__).resolve().parents[1]
RUN = Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001').resolve()
TOOL_ROOT = RUN / 'Resume008InputSource'
ALLOWED_TARGETS = ['com.apple.keylayout.ABC', 'com.apple.keylayout.US']
TOOL_LIMIT = 2 * 1024 * 1024


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value, *, exclusive=False):
    data = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()
    require(len(data) <= 32768, 'Input-source receipt exceeds32KiB')
    flags = os.O_WRONLY | os.O_NOFOLLOW | (os.O_CREAT | os.O_EXCL if exclusive else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def tool_usage():
    require(TOOL_ROOT.is_dir() and not TOOL_ROOT.is_symlink() and TOOL_ROOT.resolve() == TOOL_ROOT,
            'Declared input-source tool root is absent or noncanonical')
    logical = allocated = count = 0
    for path in [TOOL_ROOT, *TOOL_ROOT.rglob('*')]:
        require(not path.is_symlink(), 'Input-source tool root contains a symlink')
        info = path.stat()
        count += 1
        logical += info.st_size if path.is_file() else 0
        allocated += info.st_blocks * 512
        require(count <= 64, 'Input-source artifact count cap')
    require(max(logical, allocated) <= TOOL_LIMIT, 'Input-source artifact2MiB cap')
    return max(logical, allocated)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('name')
    parser.add_argument('command_json', type=Path)
    parser.add_argument('--budget', type=Path, required=True)
    parser.add_argument('--helper-sha256', required=True)
    parser.add_argument('--input-source-id', choices=ALLOWED_TARGETS, required=True)
    parser.add_argument('--runner', choices=['monitored', 'keyboard-navigation'], default='monitored')
    parser.add_argument('--timeout-seconds', type=int, default=600)
    args = parser.parse_args(argv)
    require(re.fullmatch(r'[A-Z][A-Z0-9_]{0,65}', args.name), 'Invalid run name')
    require(re.fullmatch(r'[0-9a-f]{64}', args.helper_sha256), 'Expected compiled helper SHA required')
    require(1 <= args.timeout_seconds <= 1800, 'Input-source wrapper timeout must be1..1800 seconds')
    command_path = args.command_json.resolve(strict=True)
    budget_path = args.budget.resolve(strict=True)
    limits = read_budget(budget_path)
    require(not crossed(sample(), limits), 'Baseline cumulative artifact gate')
    if args.runner == 'keyboard-navigation':
        # The older keyboard wrapper cannot forward a custom --budget. It is
        # safe to nest only if its default monitor limits equal this budget.
        require(all(limits[key] == LIMITS[key] for key in LIMITS),
                'Keyboard wrapper does not forward narrower budgets; use monitored runner')
    helper = TOOL_ROOT / 'stage9-input-source-context'
    require(helper.is_file() and not helper.is_symlink() and os.access(helper, os.X_OK),
            'Reviewed compiled helper absent; wrapper never compiles it')
    require(sha(helper) == args.helper_sha256, 'Compiled helper SHA mismatch')
    require(tool_usage() + 384 * 1024 <= TOOL_LIMIT, 'No input-source receipt/log budget remaining')
    capture_path = TOOL_ROOT / (args.name + '-original.json')
    receipt_path = TOOL_ROOT / (args.name + '-execution.json')
    log_path = TOOL_ROOT / (args.name + '-child.log')
    trace_path = TOOL_ROOT / (args.name + '-context.jsonl')
    monitor_path = PROJECT / ('STAGE9_' + args.name + '_EXECUTION.json')
    require(not any(p.exists() for p in [capture_path, receipt_path, log_path, monitor_path, trace_path]),
            'Run already exists; never overwrite or invent a retry suffix')
    binding = {'helper_sha256': args.helper_sha256, 'command_sha256': sha(command_path),
               'budget_sha256': sha(budget_path), 'wrapper_sha256': sha(Path(__file__)),
               'monitor_sha256': sha(PROJECT / 'scripts/stage9_run_monitored.py')}
    if args.runner == 'keyboard-navigation':
        binding['keyboard_wrapper_sha256'] = sha(PROJECT / 'scripts/stage9_keyboard_validation.py')
    state = {'schema': 'stage9.input-source-restoration.v1', 'name': args.name,
             'authorization': 'User authorized temporary English-keyboard testing; explicit existing ABC/U.S. only, with exact original-source restoration',
             'target_exact_id': args.input_source_id,
             'started_at': datetime.now(timezone.utc).isoformat(), 'binding': binding,
             'capture_path': str(capture_path), 'runner': args.runner, 'probe_count': 0,
             'restore_verified': False, 'state': 'preparing'}
    child = None
    original = None
    selection_attempted = False
    stop_signal = None
    old_handlers = {}
    log_handle = None
    trace_handle = None

    def interrupted(signum, frame):
        nonlocal stop_signal
        stop_signal = signum  # No exception interrupts the finally restoration.

    def invoke(operation, *identifiers):
        require(sha(helper) == args.helper_sha256, 'Compiled helper changed; cannot execute')
        command = [str(helper), operation, *identifiers]
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        require(len(result.stdout.encode()) <= 8192 and len(result.stderr.encode()) <= 8192,
                'Helper output cap')
        value = json.loads(result.stdout)
        require(isinstance(value, dict), 'Malformed helper response')
        value['helper_exit'] = result.returncode
        return value

    def snapshot(phase='during-run'):
        value = invoke('snapshot', args.input_source_id)
        require(value.get('ok') is True and value['helper_exit'] == 0, 'Input-source observation failed')
        state['probe_count'] += 1
        entry = {'at': datetime.now(timezone.utc).isoformat(), 'phase': phase, **value}
        data = (json.dumps(entry, ensure_ascii=False) + '\n').encode()
        require(trace_handle.tell() + len(data) <= 512 * 1024, 'Context trace512KiB cap')
        trace_handle.write(data)
        trace_handle.flush()
        os.fsync(trace_handle.fileno())
        return value

    def stop_owned_child():
        if child is None or child.poll() is not None:
            return
        # First allow the owned monitor to stop its separately-grouped xcodebuild
        # child and the keyboard wrapper to perform its own restoration.
        for sig, seconds in [(signal.SIGINT, 60), (signal.SIGTERM, 15), (signal.SIGKILL, 5)]:
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                break
            try:
                child.wait(timeout=seconds)
                break
            except subprocess.TimeoutExpired:
                state['forced_stop'] = True
        require(child.poll() is not None, 'Owned runner did not terminate; restore still required')

    for sig in (signal.SIGINT, signal.SIGTERM):
        old_handlers[sig] = signal.signal(sig, interrupted)
    try:
        trace_handle = trace_path.open('xb')
        state['context_trace'] = str(trace_path)
        observed = snapshot('before-selection')
        require(observed.get('originalAvailable') is True and observed.get('targetAvailable') is True,
                'Original source unavailable or explicit target not already enabled/selectable/ASCII; no changes allowed')
        original = observed['currentID']
        capture = {'schema': 'stage9.input-source-original.v1', 'original_exact_id': original,
                   'target_exact_id': args.input_source_id,
                   'observation': observed, 'binding': binding, 'captured_at': state['started_at']}
        write_json(capture_path, capture, exclusive=True)
        state['original_exact_id'] = original
        state['state'] = 'original-captured'
        write_json(receipt_path, state, exclusive=True)
        require(stop_signal is None, 'Interrupted before selection')
        selection_attempted = True  # Even an uncertain selection must be restored.
        state['select'] = invoke('select', args.input_source_id, original)
        require(state['select'].get('ok') is True and state['select']['helper_exit'] == 0,
                'Explicit target selection was not verified')
        selected = snapshot('after-selection')
        require(selected['currentID'] == args.input_source_id, 'Explicit target verification failed')
        state['selected'] = selected
        state['state'] = 'target-verified'
        write_json(receipt_path, state)
        require(stop_signal is None, 'Interrupted before child launch')
        require(sha(command_path) == binding['command_sha256'] and sha(budget_path) == binding['budget_sha256'],
                'Prepared command or budget changed')
        driver = 'stage9_keyboard_validation.py' if args.runner == 'keyboard-navigation' else 'stage9_run_monitored.py'
        child_command = [sys.executable, str(PROJECT / 'scripts' / driver), args.name, str(command_path)]
        if args.runner == 'monitored':
            child_command += ['--budget', str(budget_path)]
        log_handle = log_path.open('xb')
        child = subprocess.Popen(child_command, cwd=PROJECT, stdout=log_handle,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        state['child_pid'] = child.pid
        state['state'] = 'running'
        write_json(receipt_path, state)
        started = time.monotonic()
        while child.poll() is None:
            require(stop_signal is None, 'Input-source wrapper interrupted')
            require(time.monotonic() - started <= args.timeout_seconds, 'Input-source wrapper deadline')
            require(log_path.stat().st_size <= 256 * 1024, 'Child wrapper log exceeds256KiB')
            tool_usage()
            observed = snapshot()
            state['last_observed'] = observed
            require(observed['currentID'] == args.input_source_id, 'Input source drifted during run; stop before restoring original')
            time.sleep(0.5)
        state['child_exit'] = child.returncode
        monitor = json.loads(monitor_path.read_text())
        state['monitor_exit'] = monitor.get('monitor_exit')
        require(child.returncode == 0 and monitor.get('monitor_exit') == 0 and
                monitor.get('exit') == 0 and not monitor.get('stop_reason'),
                'Monitored command failed or stopped')
        if args.runner == 'keyboard-navigation':
            keyboard_path = PROJECT / ('STAGE9_KEYBOARD_NAVIGATION_' + args.name + '_EXECUTION.json')
            keyboard = json.loads(keyboard_path.read_text())
            state['keyboard_restore_verified'] = keyboard.get('restore_verified')
            require(keyboard.get('restore_verified') is True and keyboard.get('monitor_exit') == 0,
                    'Keyboard wrapper restoration or child result failed')
        require(snapshot('before-restoration')['currentID'] == args.input_source_id, 'Input-source final pre-restore verification failed')
        state['state'] = 'child-completed'
    except Exception as error:
        state['error'] = str(error)
        state['state'] = 'failed'
        # last_observed and its fsynced trace are the failure-time context.
        # Stop owned input producers before any further potentially slow AX read.
        try:
            stop_owned_child()
        except Exception as child_error:
            state['child_stop_error'] = str(child_error)
        if trace_handle is not None:
            try:
                state['failure_observation'] = snapshot('failure-after-child-stop')
            except Exception as observation_error:
                state['failure_observation_error'] = str(observation_error)
    finally:
        try:
            stop_owned_child()
        except Exception as error:
            state['child_stop_error'] = str(error)
        if child is not None:
            state['child_exit'] = child.poll()
        if log_handle is not None:
            log_handle.close()
        if selection_attempted and original is not None:
            try:
                state['restore'] = invoke('restore', original)
                after = snapshot('after-restoration')
                state['restored'] = after
                state['restore_verified'] = (state['restore'].get('ok') is True and
                    state['restore']['helper_exit'] == 0 and after['currentID'] == original)
            except Exception as error:
                state['restore_error'] = str(error)
        else:
            state['restore_verified'] = True
            state['restore_scope'] = 'No selection attempted'
        if trace_handle is not None:
            trace_handle.close()
            state['context_trace_sha256'] = sha(trace_path)
        state['finished_at'] = datetime.now(timezone.utc).isoformat()
        try:
            state['tool_usage_bytes'] = tool_usage()
            require(sha(Path(__file__)) == binding['wrapper_sha256'] and
                    sha(command_path) == binding['command_sha256'] and
                    sha(budget_path) == binding['budget_sha256'], 'Final input identity changed')
        except Exception as error:
            state['integrity_error'] = str(error)
        if stop_signal is not None:
            state['signal'] = stop_signal
        failed = (state.get('error') or state.get('child_stop_error') or state.get('integrity_error') or
                  stop_signal is not None or not state['restore_verified'] or state.get('child_exit') != 0)
        state['wrapper_exit'] = 3 if not state['restore_verified'] else (1 if failed else 0)
        state['state'] = 'completed' if state['wrapper_exit'] == 0 else 'failed'
        try:
            if receipt_path.exists():
                write_json(receipt_path, state)
            else:
                write_json(receipt_path, state, exclusive=True)
        except Exception as error:
            state['receipt_error'] = str(error)
            state['wrapper_exit'] = max(1, state['wrapper_exit'])
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
    print(json.dumps(state, ensure_ascii=False))
    return state['wrapper_exit']


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
