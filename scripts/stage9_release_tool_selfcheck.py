#!/usr/bin/env python3
"""Mock-only checks. No Xcode/app/cleanup; retain tiny fixtures for review."""
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import stage9_release_verify as release
import stage9_run_monitored as monitor

ARTIFACT_ROOT = Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/ToolSelfchecks')
SAFE = dict(combined_logical=100, combined_allocated=100, combined_files=1,
            derived_data_logical=50, derived_data_allocated=50)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


class Fixture:
    def __init__(self, parent):
        self.root = Path(tempfile.mkdtemp(prefix='case-', dir=parent))
        self.run = self.root / 'run'
        self.run.mkdir()
        (self.root / 'stage9_closeout_evidence').mkdir()
        for name in ['stage9_run_monitored.py', 'stage9_artifact_monitor.py']:
            p = self.root / 'scripts' / name
            p.parent.mkdir(exist_ok=True)
            p.write_text('# mock-only fingerprint input\n')
        self.source_file = self.root / 'Example.swift'
        self.source_file.write_text('// mock-only source, never compiled\n')
        self.source = self.root / 'source.json'
        write(self.source, {'Example.swift': release.sha(self.source_file)})
        self.budget = self.root / 'budget.json'
        write(self.budget, dict(monitor.LIMITS, root=str(self.run), evidence_root='stage9_closeout_evidence',
            created_at=datetime.now(timezone.utc).isoformat(), source_manifest_sha256=release.sha(self.source),
            baseline_combined_bytes=100, remaining_estimated_peak_bytes=100, projected_peak_bytes=200))
        write(self.root / 'STAGE9_RELEASE_ARTIFACT_PLAN.json', {'commands':{
            'show_release_settings_argv':['never-run-xcodebuild','-showBuildSettings'],
            'arm64_build_argv':['never-run-xcodebuild','-resultBundlePath','never','build'],
            'x86_64_build_argv':['never-run-xcodebuild','-resultBundlePath','never','build']}})
        self.stack = ExitStack()
        for module, attrs in [(release, {'ROOT':self.root,'RUN':self.run,'DD':self.run/'DerivedData',
                                        'PRODUCTS':self.run/'DerivedData/Build/Products/Release'}),
                              (monitor, {'PROJECT':self.root,'RUN':self.run})]:
            for key, value in attrs.items():
                self.stack.enter_context(patch.object(module,key,value))
        self.stack.enter_context(patch.object(release,'verify_contract',return_value={'fixture_contract':True}))
        self.prefix = 'MOCK'

    def close(self):
        self.stack.close()  # Restore Python mocks only; never remove fixture files.

    def prepare(self):
        release.prepare(self.prefix,self.source,self.budget)
        return release.prepared(self.prefix,self.budget)

    def complete(self, phase):
        def fake_execute(prefix, current, identity, provenance, conf):
            if current == 'BIND':
                value = {'source':release.source_identity(self.source),'contract':{'fixture_contract':True},
                         'sequence_sha256':release.sha(release.output(prefix,'SEQUENCE')),'fingerprints':conf['fingerprints']}
            else:
                value = {'mock_only':True}
            release.save_bound(prefix,release.PHASE_OUTPUTS[current],value,provenance)
        with patch.object(release,'monitor_context',return_value={'monitor_nonce':'mock'}), \
             patch.object(release,'assert_idle'), patch.object(release,'execute_phase',side_effect=fake_execute):
            release.dispatch(self.prefix,phase,self.budget)
        conf = release.config(self.prefix)
        cmd = release.output(self.prefix,phase+'_COMMAND')
        receipt = release.output(self.prefix,phase+'_PHASE_RECEIPT')
        write(release.output(self.prefix,phase+'_EXECUTION'), {
            'state':'completed','exit':0,'monitor_exit':0,'baseline':SAFE,'after':SAFE,
            'command':release.load(cmd),'command_sha256':release.sha(cmd),
            'release':release.monitor_identity(self.prefix,phase,conf),
            'phase_receipt_sha256':release.sha(receipt),
            'binding_sha256':release.sha(release.output(self.prefix,'BINDING'))})


class FakeChild:
    def __init__(self, exit_code=0, running=False):
        self.pid = 99999999  # Never signaled: killpg is mocked in each call.
        self.returncode = None if running else exit_code
        self.exit_code = exit_code
    def poll(self): return self.returncode
    def wait(self, timeout=None):
        self.returncode = self.exit_code
        return self.returncode


class ReleaseToolChecks(unittest.TestCase):
    parent = None
    def setUp(self):
        self.fixture = Fixture(self.parent)
        self.addCleanup(self.fixture.close)

    def test_all_nine_commands_are_dispatchers_and_budget_is_required(self):
        with self.assertRaises(RuntimeError):
            release.prepare('NO_BUDGET',self.fixture.source,None)
        conf = self.fixture.prepare()
        for phase in release.PHASES:
            cmd = release.load(release.output('MOCK',phase+'_COMMAND'))
            self.assertEqual(Path(cmd[1]).name,'stage9_release_verify.py')
            self.assertIn('--budget',cmd)
            self.assertNotIn('never-run-xcodebuild',cmd)
        self.assertEqual(len(conf['fingerprints']),15)

    def test_each_phase_requires_its_immediate_predecessor(self):
        conf = self.fixture.prepare()
        for phase in release.PHASES[1:]:
            with self.subTest(phase=phase), self.assertRaises(FileNotFoundError):
                release.preceding_receipts('MOCK',phase,conf)
        for phase in release.PHASES:
            self.fixture.complete(phase)
        prior = release.preceding_receipts('MOCK','VERIFY',conf)
        self.assertEqual(prior[-1]['phase'],'ASSEMBLE')
        self.assertEqual(len(prior),8)

    def test_settings_arm_and_intel_refuse_failure_stop_missing_after_and_threshold(self):
        conf = self.fixture.prepare()
        cases = [('BIND','SETTINGS'),('SETTINGS_CHECK','ARM64'),('INSPECT_ARM64','X86_64'),
                 ('INSPECT_X86_64','ASSEMBLE'),('ASSEMBLE','VERIFY')]
        for phase in release.PHASES:
            self.fixture.complete(phase)
        for previous, consumer in cases:
            path = release.output('MOCK',previous+'_EXECUTION')
            original = release.load(path)
            for variant in ['exit','stop','after_missing','after_threshold','monitor_exit']:
                changed = dict(original)
                if variant == 'exit': changed['exit']=9
                if variant == 'stop': changed['stop_reason']='threshold despite child0'
                if variant == 'after_missing': changed.pop('after')
                if variant == 'after_threshold': changed['after']=dict(SAFE,combined_allocated=monitor.LIMITS['cumulative_limit']+1)
                if variant == 'monitor_exit': changed['monitor_exit']=1
                write(path,changed)
                with self.subTest(previous=previous,consumer=consumer,variant=variant), self.assertRaises(RuntimeError):
                    release.preceding_receipts('MOCK',consumer,conf)
                write(path,original)

    def test_every_prepared_dependency_and_command_drift_is_rejected(self):
        conf = self.fixture.prepare()
        # Actual verification script is read-only; mutate only fake fixture inputs.
        for name in conf['fingerprints']:
            path = Path(name)
            if not path.is_relative_to(self.fixture.root): continue
            before = path.read_bytes()
            path.write_bytes(before+b' ')
            with self.subTest(path=str(path)), self.assertRaises(RuntimeError):
                release.prepared('MOCK',self.fixture.budget)
            path.write_bytes(before)

    def test_sequence_and_prepared_receipt_drift_break_chain(self):
        conf = self.fixture.prepare()
        self.fixture.complete('BIND')
        path=release.output('MOCK','PREPARED')
        value=release.load(path);value['state']='tampered';write(path,value)
        with self.assertRaises(RuntimeError):release.preceding_receipts('MOCK','SETTINGS',conf)

    def test_live_source_edit_is_rejected_before_action(self):
        self.fixture.prepare()
        self.fixture.source_file.write_text('// changed uncompiled mock source\n')
        with patch.object(release,'monitor_context',return_value={}), patch.object(release,'assert_idle'), \
             patch.object(release,'execute_phase') as action:
            with self.assertRaises(RuntimeError):release.dispatch('MOCK','BIND',self.fixture.budget)
            action.assert_not_called()

    def test_idle_gate_precedes_any_action(self):
        self.fixture.prepare()
        with patch.object(release,'monitor_context',return_value={}), \
             patch.object(release,'assert_idle',side_effect=RuntimeError('busy')),patch.object(release,'execute_phase') as action:
            with self.assertRaises(RuntimeError):release.dispatch('MOCK','BIND',self.fixture.budget)
            action.assert_not_called()

    def test_direct_phase_without_monitor_parent_is_rejected(self):
        conf=self.fixture.prepare()
        with patch.dict('os.environ',{},clear=True),self.assertRaises(RuntimeError):
            release.monitor_context('MOCK','BIND',conf)

    def test_failed_raw_build_produces_no_success_artifact(self):
        conf=self.fixture.prepare()
        with patch.object(release.subprocess,'run',return_value=subprocess.CompletedProcess([],12)) as run:
            with self.assertRaises(RuntimeError):release.execute_phase('MOCK','ARM64',{}, {},conf)
        run.assert_called_once()
        self.assertFalse(release.output('MOCK','ARM64_ACTION').exists())

    def test_budget_freshness_source_sum_and_caps(self):
        base=release.load(self.fixture.budget)
        variants=[dict(base,created_at=(datetime.now(timezone.utc)-timedelta(hours=25)).isoformat()),
                  dict(base,source_manifest_sha256='wrong'),dict(base,projected_peak_bytes=201),
                  dict(base,cumulative_limit=monitor.LIMITS['cumulative_limit']+1)]
        for value in variants:
            write(self.fixture.budget,value)
            with self.assertRaises(RuntimeError):monitor.read_budget(self.fixture.budget,release=True,source_sha=release.sha(self.fixture.source))

    def run_monitor(self, *, code=0, snapshots=None, running=False, name='MOCKRUN'):
        cmd=self.fixture.root/(name+'.json');write(cmd,['never-run-build-or-app'])
        child=FakeChild(code,running=running)
        with patch.object(monitor,'sample',side_effect=snapshots or [SAFE,SAFE]), \
             patch.object(monitor.subprocess,'Popen',return_value=child) as popen, \
             patch.object(monitor.os,'killpg') as signal_child:
            status=monitor.main([name,str(cmd)])
        return status,release.load(self.fixture.root/('STAGE9_'+name+'_EXECUTION.json'))

    def test_monitor_child_failure_is_nonzero(self):
        status,result=self.run_monitor(code=7)
        self.assertEqual(status,7)
        self.assertFalse(monitor.execution_succeeded(result,monitor.LIMITS))

    def test_monitor_clean_success_has_final_receipt(self):
        status,result=self.run_monitor()
        self.assertEqual(status,0)
        self.assertTrue(monitor.execution_succeeded(result,monitor.LIMITS))

    def test_monitor_after_only_threshold_is_nonzero_even_child_zero(self):
        high=dict(SAFE,combined_allocated=monitor.LIMITS['cumulative_limit']+1)
        status,result=self.run_monitor(snapshots=[SAFE,high])
        self.assertNotEqual(status,0)
        self.assertEqual(result['exit'],0)
        self.assertEqual(result['stop_reason'],'after artifact threshold')

    def test_monitor_midrun_stop_is_nonzero_even_child_zero_and_after_safe(self):
        high=dict(SAFE,combined_files=50001)
        status,result=self.run_monitor(snapshots=[SAFE,high,SAFE],running=True)
        self.assertNotEqual(status,0)
        self.assertEqual(result['exit'],0)
        self.assertEqual(result['stop_reason'],'artifact threshold')

    def test_monitor_baseline_gate_never_spawns(self):
        high=dict(SAFE,derived_data_allocated=2147483649)
        cmd=self.fixture.root/'baseline.json';write(cmd,['never-run-build-or-app'])
        with patch.object(monitor,'sample',side_effect=[high,high]),patch.object(monitor.subprocess,'Popen') as launch:
            self.assertNotEqual(monitor.main(['BASELINE',str(cmd)]),0)
            launch.assert_not_called()

    def test_monitor_detects_command_and_budget_drift_after_child_zero(self):
        for kind in ['command','budget']:
            with self.subTest(kind=kind):
                name='DRIFT_'+kind.upper()
                cmd=self.fixture.root/(name+'.json');write(cmd,['never-run-build-or-app'])
                calls=0
                def observe():
                    nonlocal calls
                    calls+=1
                    if calls==2:
                        target=cmd if kind=='command' else self.fixture.budget
                        target.write_text(target.read_text()+' ')
                    return SAFE
                with patch.object(monitor,'sample',side_effect=observe), \
                     patch.object(monitor.subprocess,'Popen',return_value=FakeChild(0)),patch.object(monitor.os,'killpg'):
                    status=monitor.main([name,str(cmd),'--budget',str(self.fixture.budget)])
                self.assertNotEqual(status,0)
                result=release.load(self.fixture.root/('STAGE9_'+name+'_EXECUTION.json'))
                self.assertEqual(result['exit'],0)
                self.assertIn('final integrity check failed',result['stop_reason'])

    def test_verification_script_fingerprint_drift_is_rejected(self):
        self.fixture.prepare()
        actual_sha=release.sha
        script=Path(release.__file__).resolve()
        with patch.object(release,'sha',side_effect=lambda p:'changed' if p.resolve()==script else actual_sha(p)):
            with self.assertRaises(RuntimeError):release.prepared('MOCK',self.fixture.budget)

    def test_retained_paths_are_prefix_bound_and_validate_prefix(self):
        arm, fat = release.retained_paths('MOCK')
        other_arm, other_fat = release.retained_paths('OTHER')
        self.assertEqual(arm.parent, release.PRODUCTS)
        self.assertEqual(fat.parent, release.PRODUCTS)
        self.assertEqual(len({arm, fat, other_arm, other_fat}), 4)
        self.assertNotEqual(arm, release.ARM)
        for value in ['../outside', 'bad/prefix', '', 'lowercase']:
            with self.subTest(prefix=value), self.assertRaises(RuntimeError):
                release.retained_paths(value)

    def test_prepare_rejects_existing_files_directories_and_dangling_links(self):
        for kind in ['ARM', 'FAT', 'DIR', 'LINK']:
            prefix = 'EXISTING_' + kind
            arm, fat = release.retained_paths(prefix)
            target = fat if kind == 'FAT' else arm
            target.parent.mkdir(parents=True, exist_ok=True)
            if kind == 'DIR': target.mkdir()
            elif kind == 'LINK': target.symlink_to('missing-fixture-target')
            else: target.write_bytes(b'retained sentinel')
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                release.prepare(prefix, self.fixture.source, self.fixture.budget)
            self.assertFalse(release.output(prefix, 'SEQUENCE').exists())
            if kind in ['ARM', 'FAT']:
                self.assertEqual(target.read_bytes(), b'retained sentinel')

    def test_retained_paths_reject_rebound_outside_or_other_prefix(self):
        conf = self.fixture.prepare()
        receipt = release.load(release.output('MOCK', 'PREPARED'))
        for replacement in [str(self.fixture.root / 'outside.binary'),
                            str(release.retained_paths('OTHER')[0])]:
            modified = dict(conf, retained_arm_path=replacement)
            write(release.output('MOCK', 'SEQUENCE'), modified)
            write(release.output('MOCK', 'PREPARED'), dict(receipt,
                sequence_sha256=release.sha(release.output('MOCK', 'SEQUENCE'))))
            with self.subTest(path=replacement), self.assertRaisesRegex(RuntimeError, 'path binding mismatch'):
                release.prepared('MOCK', self.fixture.budget)
            with self.subTest(dispatch_path=replacement), self.assertRaisesRegex(RuntimeError, 'path binding mismatch'):
                release.execute_phase('MOCK', 'INSPECT_ARM64', {}, {}, modified)

    def test_new_universal_main_still_requires_exact_macos_13(self):
        _, fat = release.retained_paths('MOCK')
        def inspection(argv, **kwargs):
            if argv[:3] == ['xcrun', 'lipo', '-archs']:
                return {'stdout': 'arm64'}
            if argv[:2] == ['xcrun', 'vtool']:
                return {'stdout': 'platform MACOS\nminos 12.0\n'}
            raise AssertionError('Must stop before later inspection: ' + repr(argv))
        with patch.object(release, 'command', side_effect=inspection):
            with self.assertRaisesRegex(RuntimeError, 'Main executable minimum must equal13.0'):
                release.binary_details(fat, ['arm64'], main_executable=True)

    def test_actual_python_shell_propagates_mock_child_failure(self):
        # Only another Python instance runs, with Popen mocked there as well.
        done=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--shell-probe',str(self.parent)],
                            capture_output=True,text=True)
        self.assertEqual(done.returncode,7,done.stdout+done.stderr)


def shell_probe(parent):
    fixture=Fixture(parent)
    try:
        cmd=fixture.root/'shell.json';write(cmd,['never-run-build-or-app'])
        with patch.object(monitor,'sample',side_effect=[SAFE,SAFE]), \
             patch.object(monitor.subprocess,'Popen',return_value=FakeChild(7)),patch.object(monitor.os,'killpg'):
            return monitor.main(['SHELL',str(cmd)])
    finally:fixture.close()


def main():
    ARTIFACT_ROOT.mkdir(exist_ok=True)
    parent=Path(tempfile.mkdtemp(prefix='release-tools-',dir=ARTIFACT_ROOT))
    ReleaseToolChecks.parent=parent
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseToolChecks)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    record={'mode':'mock-only-no-build-no-app-no-cleanup','tests_run':result.testsRun,
            'failures':len(result.failures),'errors':len(result.errors),'success':result.wasSuccessful(),
            'fixture_root':str(parent),'retained_files':sum(1 for p in parent.rglob('*') if p.is_file()),
            'retained_bytes':sum(p.stat().st_size for p in parent.rglob('*') if p.is_file()),
            'tool_sha256':{str(Path(m.__file__).resolve()):hashlib.sha256(Path(m.__file__).read_bytes()).hexdigest()
                           for m in [release,monitor]},'artifact_disposition':'Retain tiny mocks; no deletion performed'}
    path=parent/'selfcheck.json';write(path,record)
    print(json.dumps({'selfcheck':str(path),**record},ensure_ascii=False))
    return 0 if result.wasSuccessful() else 1


if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--shell-probe':raise SystemExit(shell_probe(Path(sys.argv[2])))
    raise SystemExit(main())
