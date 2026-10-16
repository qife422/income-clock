#!/usr/bin/env python3
"""Bounded diagnostic: use only with explicit authorization after an artifact gate.
The inventory never follows symlinks. Reports must be outside the affected root.
"""
import argparse, json, os, signal, stat, subprocess, time, threading
from pathlib import Path

def inventory(root):
    entries = []
    for base, dirs, names in os.walk(root, followlinks=False):
        for name in names:
            path = Path(base) / name
            try:
                s = path.lstat()
            except FileNotFoundError:
                continue
            entries.append(dict(path=str(path.relative_to(root)), logical=s.st_size,
                allocated=s.st_blocks * 512, symlink=stat.S_ISLNK(s.st_mode),
                regular=stat.S_ISREG(s.st_mode), inode=s.st_ino, device=s.st_dev))
    regular = [e for e in entries if e['regular']]
    return dict(logical=sum(e['logical'] for e in regular),
        allocated=sum(e['allocated'] for e in regular), files=len(entries),
        symlinks=sum(e['symlink'] for e in entries),
        _entries={e['path']:e for e in regular},
        largest=sorted(regular, key=lambda e: e['logical'], reverse=True)[:30])

def compact(snapshot):
    return {k:v for k,v in snapshot.items() if k != '_entries'}

def processes():
    output = subprocess.run(['ps','-axo','pid,ppid,pgid,command'], capture_output=True, text=True).stdout
    return '\n'.join(line for line in output.splitlines() if any(term in line for term in ['xcodebuild','XCBBuildService','swift-frontend','clang','stage9-closeout','stage9_artifact_monitor']))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', type=Path, required=True)
    ap.add_argument('--additional-root', type=Path, action='append', default=[])
    ap.add_argument('--report', type=Path, required=True)
    ap.add_argument('--command-json', type=Path)
    ap.add_argument('--seconds', type=int, default=30)
    ap.add_argument('--authorized-diagnostic', action='store_true')
    a = ap.parse_args()
    root, report = a.root.resolve(strict=True), a.report.resolve()
    if report == root or root in report.parents:
        ap.error('report must be outside affected root')
    extra_roots = [p.resolve(strict=True) for p in a.additional_root]
    extras = [compact(inventory(p)) for p in extra_roots]
    baseline = inventory(root)
    def crosses(s):
        return (s['logical'] + sum(e['logical'] for e in extras) > 1073741824
            or s['allocated'] + sum(e['allocated'] for e in extras) > 1073741824
            or s['files'] > 50000)

    result = dict(root=str(root), baseline=compact(baseline), additional_roots=[dict(root=str(p), **e) for p,e in zip(extra_roots,extras)], samples=[], mode='read-only')
    if a.command_json:
        if not a.authorized_diagnostic or not 1 <= a.seconds <= 30:
            ap.error('explicitly authorized diagnostic with <=30 second budget required')
        if crosses(baseline):
            ap.error('baseline already crosses a threshold; do not expand')
        cmd = json.loads(a.command_json.read_text())
        result.update(mode='authorized bounded diagnostic', command=cmd)
        # Put all new diagnostic logs outside the affected tree.
        with report.with_suffix('.log').open('w') as log:
            process = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            began = time.monotonic()
            def interrupt():
                try: os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError: pass
            watchdog = threading.Timer(a.seconds, interrupt)
            watchdog.start()
            result['processes_before'] = processes()
            while process.poll() is None:
                sample = inventory(root)
                sample['elapsed'] = time.monotonic() - began
                growth = []
                for path, e in sample['_entries'].items():
                    previous = baseline['_entries'].get(path, {})
                    delta = e['logical'] - previous.get('logical', 0)
                    if delta > 0:
                        growth.append(dict(**e, logical_growth=delta,
                            allocated_growth=e['allocated']-previous.get('allocated',0)))
                sample = compact(sample)
                sample['growth'] = sorted(growth,key=lambda e:e['logical_growth'],reverse=True)[:40]
                trigger = crosses(sample)
                if trigger:
                    interrupt()
                    result['processes_at_threshold'] = processes()
                    peak_paths = [str(root / e['path']) for e in sample['growth'][:10]]
                    if peak_paths:
                        result['open_peak_files'] = subprocess.run(['lsof','-nP','--',*peak_paths],capture_output=True,text=True,timeout=5).stdout
                result['samples'].append(sample)
                # Save the exact peak paths before interrupting a transient producer.
                report.write_text(json.dumps(result, indent=2) + '\n')
                trigger = crosses(sample)
                if trigger or sample['elapsed'] >= a.seconds:
                    result['stop_reason'] = 'threshold' if trigger else '30-second diagnostic budget'
                    interrupt()
                    break
                time.sleep(0.2)
            try:
                result['exit'] = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                result['exit'] = process.wait(timeout=10)
        watchdog.cancel()
        result.setdefault('stop_reason', 'completed' if time.monotonic()-began < a.seconds else '30-second diagnostic budget')
        result['after'] = compact(inventory(root))
    report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['mode', 'stop_reason', 'exit'] if k in result}))

if __name__ == '__main__':
    main()
