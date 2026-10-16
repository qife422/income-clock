#!/usr/bin/env python3
"""Authorized Stage9 execution; every failed/over-budget run has a failing exit."""
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
import uuid

from stage9_artifact_monitor import inventory, compact

PROJECT = Path(__file__).resolve().parents[1]
RUN = Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001')
LIMITS = {'cumulative_limit': 3489660928, 'derived_data_limit': 2147483648, 'file_limit': 50000}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_budget(path, *, release=False, source_sha=None, now=None):
    """Explicit budgets may narrow, but never enlarge, current authorized caps."""
    if path is None:
        require(not release, 'Release requires an explicit fresh --budget')
        return dict(LIMITS)
    path = Path(path).resolve(strict=True)
    value = json.loads(path.read_text())
    for key, ceiling in LIMITS.items():
        require(type(value.get(key)) is int and 0 < value[key] <= ceiling,
                'Invalid/unapproved budget limit: ' + key)
    require(Path(value['root']).resolve() == RUN.resolve(), 'Budget uses another run root')
    evidence = Path(value['evidence_root'])
    if not evidence.is_absolute():
        evidence = PROJECT / evidence
    require(evidence.resolve() == (PROJECT / 'stage9_closeout_evidence').resolve(),
            'Budget uses another evidence root')
    if release:
        created = datetime.fromisoformat(value['created_at'].replace('Z', '+00:00'))
        require(created.tzinfo is not None, 'Budget created_at must include timezone')
        now = now or datetime.now(timezone.utc)
        age = (now - created).total_seconds()
        require(0 <= age <= 24 * 3600, 'Release budget is future-dated or older than24h')
        require(value.get('source_manifest_sha256') == source_sha, 'Budget/source binding mismatch')
        keys = ['baseline_combined_bytes', 'remaining_estimated_peak_bytes', 'projected_peak_bytes']
        require(all(type(value.get(k)) is int and value[k] >= 0 for k in keys),
                'Budget requires nonnegative baseline/remaining/projected byte counts')
        require(value[keys[0]] + value[keys[1]] == value[keys[2]] <= value['cumulative_limit'],
                'Budget baseline + remaining estimate must equal projected peak within cap')
    return value


def sample():
    s = compact(inventory(RUN))
    evidence = compact(inventory(PROJECT / 'stage9_closeout_evidence'))
    derived = compact(inventory(RUN / 'DerivedData'))
    prefixes = ('STAGE9_CANDIDATE', 'STAGE9_CLOSURE', 'STAGE9_CLOSEOUT', 'STAGE9_KEYBOARD',
                'STAGE9_RESUME', 'STAGE9_RELEASE', 'STAGE9_CACHE_DISPOSITION', 'STAGE9_NATIVE',
                'STAGE9_CHOOSER', 'STAGE9_VALIDATION', 'STAGE9_STARTUP', 'STAGE9_PAUSE', 'STAGE9_FINISH')
    metadata = [p.stat() for p in PROJECT.iterdir() if p.is_file() and p.name.startswith(prefixes)]
    s['root_metadata_logical'] = sum(p.st_size for p in metadata)
    s['root_metadata_allocated'] = sum(p.st_blocks * 512 for p in metadata)
    # Existing exact debugger-cache candidates remain counted; no cleanup here.
    diagnostic = PROJECT / 'STAGE9_RESUME004_NATIVE_DIAGNOSIS.json'
    external = []
    if diagnostic.exists():
        for item in json.loads(diagnostic.read_text()).get('debugger_cache', {}).get('files', []):
            candidate = Path(item['path'])
            if candidate.is_file():
                external.append(candidate.stat())
    s['diagnostic_external_logical'] = sum(p.st_size for p in external)
    s['diagnostic_external_allocated'] = sum(p.st_blocks * 512 for p in external)
    s['combined_logical'] = s['logical'] + evidence['logical'] + s['root_metadata_logical'] + s['diagnostic_external_logical']
    s['combined_allocated'] = s['allocated'] + evidence['allocated'] + s['root_metadata_allocated'] + s['diagnostic_external_allocated']
    s['combined_files'] = s['files'] + evidence['files'] + len(metadata) + len(external)
    s['derived_data_logical'] = derived['logical']
    s['derived_data_allocated'] = derived['allocated']
    return s


def crossed(snapshot, limits=None):
    limits = limits or LIMITS
    return (max(snapshot['combined_logical'], snapshot['combined_allocated']) > limits['cumulative_limit']
            or max(snapshot['derived_data_logical'], snapshot['derived_data_allocated']) > limits['derived_data_limit']
            or snapshot['combined_files'] > limits['file_limit'])


def execution_succeeded(result, limits):
    """Missing final observations and a successful child after a stop both fail."""
    if (result.get('exit') != 0 or result.get('monitor_exit') != 0
            or result.get('state') != 'completed' or 'stop_reason' in result
            or not isinstance(result.get('after'), dict)):
        return False
    try:
        return not crossed(result['after'], limits) and not crossed(result['baseline'], limits)
    except (KeyError, TypeError):
        return False


def stop_child(child):
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        if child.poll() is not None:
            return child.returncode
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        try:
            return child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
    raise RuntimeError('Owned child process did not terminate')


def run_monitored(name, command_path, *, budget_path=None, release_prefix=None, phase=None):
    require(re.fullmatch(r'[A-Z][A-Z0-9_]{0,65}', name), 'Invalid run identifier')
    command_path = Path(command_path).resolve(strict=True)
    argv = json.loads(command_path.read_text())
    require(isinstance(argv, list) and argv and all(isinstance(x, str) for x in argv), 'Command must be argv strings')
    report = PROJECT / ('STAGE9_' + name + '_EXECUTION.json')
    log_path = PROJECT / ('STAGE9_' + name + '.log')
    require(not report.exists() and not log_path.exists(), 'Run identifier already used')
    release = None
    # Release dispatcher commands must not run in the unbound generic mode.
    is_release = any(Path(arg).name == 'stage9_release_verify.py' for arg in argv)
    require(is_release == (release_prefix is not None and phase is not None), 'Release command requires --release-prefix and --phase')
    limits = read_budget(budget_path)
    if is_release:
        import stage9_release_verify as release
        require(name == release_prefix + '_' + phase, 'Release run/phase mismatch')
        conf = release.prepared(release_prefix, budget_path)
        require(command_path == release.output(release_prefix, phase + '_COMMAND').resolve(), 'Unexpected Release command path')
        require(argv == release.load(command_path), 'Release command changed')
        limits = read_budget(budget_path, release=True, source_sha=conf['source_manifest_sha256'])
    result = {'command': argv, 'command_path': str(command_path), 'command_sha256': sha(command_path),
              'monitor_pid': os.getpid(), 'nonce': str(uuid.uuid4()), 'samples': [], 'state': 'starting',
              'monitor_sha256': sha(Path(__file__)), 'artifact_monitor_sha256': sha(PROJECT / 'scripts/stage9_artifact_monitor.py'),
              'budget_path': str(Path(budget_path).resolve()) if budget_path else None,
              'budget_sha256': sha(Path(budget_path)) if budget_path else None,
              'limits': {key: limits[key] for key in LIMITS}}
    if release:
        result['release'] = release.monitor_identity(release_prefix, phase, conf)
    # Exclusive receipt exists before the child starts, for its parent handshake.
    with report.open('x') as handle:
        json.dump(result, handle, indent=2)
    child = None
    began = time.monotonic()
    old_handlers = {}
    def interrupted(signum, frame):
        result['stop_reason'] = 'monitor signal ' + str(signum)
        raise KeyboardInterrupt
    try:
        result['baseline'] = sample()
        require(not crossed(result['baseline'], limits), 'baseline artifact threshold')
        result['state'] = 'running'
        report.write_text(json.dumps(result, indent=2) + '\n')
        for sig in (signal.SIGINT, signal.SIGTERM):
            old_handlers[sig] = signal.signal(sig, interrupted)
        env = dict(os.environ, STAGE9_MONITOR_RECEIPT=str(report), STAGE9_MONITOR_NONCE=result['nonce'])
        with log_path.open('x') as log:
            child = subprocess.Popen(argv, cwd=PROJECT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            while child.poll() is None:
                current = sample()
                current['elapsed'] = time.monotonic() - began
                if crossed(current, limits):
                    result['stop_reason'] = 'artifact threshold'
                    result['threshold_snapshot'] = current
                    break
                if not result['samples'] or current['elapsed'] - result['samples'][-1]['elapsed'] > 5:
                    result['samples'].append(current)
                time.sleep(0.2)
            result['exit'] = stop_child(child) if 'stop_reason' in result else child.wait(timeout=10)
    except KeyboardInterrupt:
        result.setdefault('stop_reason', 'monitor interrupted')
    except Exception as error:
        result['stop_reason'] = 'monitor error: ' + str(error)
    finally:
        if child is not None:
            try:
                result['exit'] = stop_child(child)
            except Exception as error:
                result['stop_reason'] = 'child termination error: ' + str(error)
        try:
            result['after'] = sample()
            if crossed(result['after'], limits):
                result.setdefault('stop_reason', 'after artifact threshold')
        except Exception as error:
            result['after_error'] = str(error)
            result.setdefault('stop_reason', 'final inventory failed')
        try:
            require(sha(command_path) == result['command_sha256'], 'Command changed during execution')
            require(sha(Path(__file__)) == result['monitor_sha256'], 'Monitor changed during execution')
            require(sha(PROJECT / 'scripts/stage9_artifact_monitor.py') == result['artifact_monitor_sha256'], 'Artifact monitor changed during execution')
            if budget_path:
                require(sha(Path(budget_path)) == result['budget_sha256'], 'Budget changed during execution')
            if release:
                fresh = release.prepared(release_prefix, budget_path)
                require(release.monitor_identity(release_prefix, phase, fresh) == result['release'], 'Release input changed during execution')
                receipt = release.output(release_prefix, phase + '_PHASE_RECEIPT')
                require(receipt.is_file(), 'Release phase receipt absent')
                result['phase_receipt_sha256'] = sha(receipt)
                result['binding_sha256'] = sha(release.output(release_prefix, 'BINDING'))
        except Exception as error:
            result.setdefault('stop_reason', 'final integrity check failed: ' + str(error))
        result['elapsed'] = time.monotonic() - began
        child_exit = result.get('exit', 1)
        result['monitor_exit'] = (child_exit if type(child_exit) is int and child_exit > 0 else 1) if child_exit != 0 or 'stop_reason' in result else 0
        result['state'] = 'completed' if result['monitor_exit'] == 0 else 'failed'
        report.write_text(json.dumps(result, indent=2) + '\n')
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
    print(json.dumps({k: result[k] for k in ['exit', 'monitor_exit', 'elapsed', 'stop_reason'] if k in result}))
    return result['monitor_exit']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('command_json', type=Path)
    parser.add_argument('--budget', type=Path)
    parser.add_argument('--release-prefix')
    parser.add_argument('--phase')
    args = parser.parse_args(argv)
    return run_monitored(args.name, args.command_json, budget_path=args.budget,
                         release_prefix=args.release_prefix, phase=args.phase)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
