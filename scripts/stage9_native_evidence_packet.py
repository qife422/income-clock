#!/usr/bin/env python3
"""Select bounded native result evidence into a new, non-overwriting packet."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

from stage9_run_monitored import RUN, PROJECT, sample, LIMITS


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def get(kind, raw, test=None):
    args = ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(raw)]
    if test:
        args += ['--test-id', test]
    result = subprocess.run(args, capture_output=True, check=True)
    assert len(result.stdout) <= 2 * 1024 * 1024
    return result.stdout, json.loads(result.stdout)


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('name')
    parser.add_argument('packet')
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    assert re.fullmatch(r'RESUME01(?:0|1)_[A-Z_]+', args.name)
    assert re.fullmatch(r'resume01(?:0|1)-[a-z-]+', args.packet)
    prefix = 'STAGE9_' + args.name
    command_file = PROJECT / (prefix + '_COMMAND.json')
    command = json.loads(command_file.read_text())
    raw = Path(command[command.index('-resultBundlePath') + 1])
    assert raw.parent == RUN / 'Results' and raw.suffix == '.xcresult'
    assert (raw / 'Info.plist').is_file()
    raw_files = [p for p in raw.rglob('*') if p.is_file()]
    assert not any(p.is_symlink() for p in raw.rglob('*'))
    raw_bytes = sum(p.stat().st_size for p in raw_files)
    assert len(raw_files) <= 2000 and raw_bytes <= 128 * 1024 * 1024
    source = json.loads(args.source.read_text())
    assert len(source) == 93
    for relative, digest in source.items():
        assert (PROJECT / relative).is_relative_to(PROJECT)
        assert sha(PROJECT / relative) == digest
    source_bytes = sum((PROJECT / p).stat().st_size for p in source)
    summary_data, summary = get('summary', raw)
    tests_data, tests = get('tests', raw)
    cases = [x for x in objects(tests) if x.get('nodeType') == 'Test Case']
    assert len(cases) == summary['totalTestCount']
    activities = []
    selected = {}
    unavailable_attachments = []
    for case in cases:
        data, tree = get('activities', raw, case['nodeIdentifierURL'])
        activities.append(data)
        listed = [a for x in objects(tree) for a in x.get('attachments', [])]
        # Xcode retains metadata for deleteOnSuccess attachments with no payload.
        for a in listed:
            if 'payloadId' not in a:
                assert a.get('lifetime') == 'deleteOnSuccess' or (a.get('lifetime') == '' and a.get('name') == 'Complete Issue Description.txt')
                unavailable_attachments.append({'test': case['nodeIdentifierURL'], **a})
        attachments = {a['payloadId']: a for a in listed if 'payloadId' in a}
        for key, attachment in attachments.items():
            if attachment.get('lifetime') == 'keepAlways':
                selected[key] = attachment
        if case['result'] != 'Passed':
            images = sorted((a for a in attachments.values() if a['name'].endswith(('.heic', '.png'))),
                            key=lambda a: a.get('timestamp', 0))
            for attachment in images[-3:]:
                selected[attachment['payloadId']] = attachment
    assert len(selected) <= 64
    baseline = sample()
    # Includes selected exports and metadata, with no cleanup credit.
    assert max(baseline['combined_logical'], baseline['combined_allocated']) + raw_bytes + source_bytes + 64 * 1024 * 1024 < LIMITS['cumulative_limit']
    out = PROJECT / 'stage9_closeout_evidence' / args.packet
    out.mkdir()
    for child in ['raw', 'selected', 'records', 'source']:
        (out / child).mkdir()
    for p in raw_files:
        target = out / 'raw' / raw.name / p.relative_to(raw)
        target.parent.mkdir(parents=True, exist_ok=True)
        assert not target.exists()
        shutil.copyfile(p, target)
        assert sha(p) == sha(target)
    for relative in source:
        target = out / 'source' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PROJECT / relative, target)
        assert sha(target) == source[relative]
    exports = []
    total_selected = 0
    for i, attachment in enumerate(selected.values()):
        suffix = Path(attachment['name']).suffix
        if suffix not in ['.png', '.heic', '.json', '.txt']:
            suffix = '.bin'
        target = out / 'selected' / (f'{i:02d}' + suffix)
        assert not target.exists()
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'object', '--legacy', '--path', str(raw),
                        '--id', attachment['payloadId'], '--type', 'file', '--output-path', str(target)],
                       capture_output=True, check=True)
        total_selected += target.stat().st_size
        assert target.stat().st_size <= 12 * 1024 * 1024 and total_selected <= 64 * 1024 * 1024
        exports.append({**attachment, 'path': str(target.relative_to(out)), 'bytes': target.stat().st_size,
                        'sha256': sha(target)})
    (out / 'records' / 'summary.json').write_bytes(summary_data)
    (out / 'records' / 'tests.json').write_bytes(tests_data)
    for i, data in enumerate(activities):
        (out / 'records' / f'activities-{i}.json').write_bytes(data)
    required = [command_file, PROJECT / (prefix + '_EXECUTION.json'), PROJECT / (prefix + '.log'),
                PROJECT / ('STAGE9_KEYBOARD_NAVIGATION_' + args.name + '_EXECUTION.json'),
                args.source, Path(__file__)]
    required += [RUN / 'Resume008InputSource' / (args.name + '-' + suffix)
                 for suffix in ['original.json', 'execution.json', 'context.jsonl', 'child.log']]
    for p in required:
        assert p.is_file()
        shutil.copyfile(p, out / 'records' / p.name)
    manifest = {'classification': 'fixed native evidence candidate; independent predicate review required',
                'name': args.name, 'source_manifest': args.source.name,
                'method_results': [{'id': c['nodeIdentifierURL'], 'result': c['result']} for c in cases],
                'producer_command': ['python3', str(Path(__file__)), args.name, args.packet, str(args.source)],
                'raw_bytes': raw_bytes, 'source_bytes': source_bytes, 'selected': exports,
                'unavailable_attachment_metadata': unavailable_attachments,
                'limits': 'No full-row promotion; restoration and input phases reviewed separately. Original exports only; no stdout status suffix.',
                'files': {str(p.relative_to(out)): {'bytes': p.stat().st_size, 'sha256': sha(p)}
                          for p in out.rglob('*') if p.is_file()}}
    (out / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'packet': str(out), 'raw_bytes': raw_bytes, 'selected_bytes': total_selected,
                      'files': len(manifest['files']), 'methods': manifest['method_results']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
