#!/usr/bin/env python3
"""Sequential unsigned Release verification. No app launch, signing, or cleanup.

prepare only writes small command JSONs. Every executable command is later run by
the existing stage9_run_monitored.py after the root coordinator releases the DD.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys

import stage9_run_monitored as monitored

ROOT = Path(__file__).resolve().parents[1]
RUN = Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001')
DD = RUN / 'DerivedData'
PRODUCTS = DD / 'Build/Products/Release'
APP = PRODUCTS / 'IncomeClock.app'
EXE = APP / 'Contents/MacOS/IncomeClock'
ARM = PRODUCTS / 'IncomeClock.arm64.binary'
FAT = PRODUCTS / 'IncomeClock.universal.binary'
CONTRACT = ROOT / 'contract_snapshots/2026-08-17-pd2rr-007-recovery-transaction-repair-candidates/SHA256SUMS'
MAGICS = {bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
TOKENS = ['STAGE9_ISOLATED_TEST_BUILD','INCOMECLOCK_TEST_ROOT','INCOMECLOCK_UI_ISOLATION_NONCE',
          'INCOMECLOCK_RECOVERY_NONCE','INCOMECLOCK_FOCUS_HARNESS_RESULT','XCTestConfigurationFilePath',
          'SettingsRecoveryHarness','Stage9RecoveryBootstrap','PanelFocusHarness','--debug-now-ms',
          '--debug-time-rate','AdvancingClock','ui-isolation-receipt.json','bootstrap-claim-']

def require(value, message):
    if not value: raise RuntimeError(message)

def digest_bytes(value): return hashlib.sha256(value).hexdigest()
def sha(path): return digest_bytes(path.read_bytes())
def output(prefix, label): return ROOT / f'STAGE9_{prefix}_{label}.json'
def load(path): return json.loads(path.read_text())
def save(path, value):
    with path.open('x') as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write('\n')

def command(argv, allowed=(0,)):
    # argv is always a list; neither shell=True nor shell interpolation is used.
    done = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    text = done.stdout.decode('utf-8', errors='replace')
    error = done.stderr.decode('utf-8', errors='replace')
    require(done.returncode in allowed, f'Command failed ({done.returncode}): {argv!r}\n{error[:2000]}')
    return dict(argv=argv, exit=done.returncode, stdout=text, stderr=error,
                stdout_sha256=digest_bytes(done.stdout), stderr_sha256=digest_bytes(done.stderr))

def assert_idle():
    processes = command(['ps','-axo','pid=,comm='])['stdout'].splitlines()
    active = []
    for line in processes:
        parts = line.strip().split(None, 1)
        if len(parts) != 2: continue
        name = Path(parts[1]).name
        if name in {'xcodebuild','swift-frontend','clang','IncomeClock','IncomeClockUITests-Runner'}:
            active.append(line)
    require(not active, 'Shared build/app consumer still active: '+repr(active))

def normalize_body(path):
    text = path.read_text()
    return text.split('---', 2)[-1] if text.startswith('---\n') else text

def verify_contract():
    actual = {}
    for line in CONTRACT.read_text().splitlines():
        if not line.strip(): continue
        expected, name = line.split(None, 1)
        path = CONTRACT.parent / name.lstrip('*')
        require(sha(path) == expected, f'Contract snapshot changed: {path}')
        actual[str(path)] = expected
        active_name = next((s for s in ['SPEC','UI_SPEC','TECH_SPEC'] if path.name.startswith(s+'-')), None)
        require(active_name is not None, f'Unexpected Contract filename {path.name}')
        active = ROOT / (active_name+'.md')
        require(normalize_body(active) == normalize_body(path), f'Active Contract body differs: {active}')
        actual[str(active)] = sha(active)
    return {'manifest_path':str(CONTRACT),'manifest_sha256':sha(CONTRACT),'files':actual}

def source_identity(path):
    manifest = load(path)
    require(isinstance(manifest, dict) and manifest, 'Source manifest must be nonempty path-to-SHA mapping')
    for name, fingerprint in manifest.items():
        candidate = ROOT / name
        require(not Path(name).is_absolute() and '..' not in Path(name).parts, 'Unsafe source manifest path')
        require(candidate.resolve().is_relative_to(ROOT.resolve()), 'Source escapes project')
        require(candidate.is_file() and sha(candidate) == fingerprint, f'Source mismatch: {name}')
    return {'manifest_path':str(path),'manifest_sha256':sha(path),'files':manifest}

PHASES = ['BIND','SETTINGS','SETTINGS_CHECK','ARM64','INSPECT_ARM64','X86_64','INSPECT_X86_64','ASSEMBLE','VERIFY']
PHASE_OUTPUTS = {'BIND':'BINDING','SETTINGS':'SETTINGS_ACTION','SETTINGS_CHECK':'SETTINGS_VERIFIED',
                 'ARM64':'ARM64_ACTION','INSPECT_ARM64':'ARM64_INSPECTION','X86_64':'X86_64_ACTION',
                 'INSPECT_X86_64':'X86_64_INSPECTION','ASSEMBLE':'ASSEMBLED','VERIFY':'FINAL_VERIFICATION'}

def retained_paths(prefix):
    require(re.fullmatch(r'[A-Z][A-Z0-9_]{0,40}', prefix), 'Invalid retained-slice prefix')
    require(PRODUCTS == DD / 'Build/Products/Release' and PRODUCTS.resolve() == PRODUCTS,
            'Retained slices require the declared non-symlink Release product root')
    return (PRODUCTS / f'IncomeClock.{prefix}.arm64.binary',
            PRODUCTS / f'IncomeClock.{prefix}.universal.binary')


def require_new_retained_target(path):
    require(not path.exists() and not path.is_symlink(), 'Retained slice target already exists: ' + str(path))


def config(prefix): return load(output(prefix, 'SEQUENCE'))

def prepared(prefix, budget_path):
    require(budget_path is not None, 'Every Release phase requires explicit --budget')
    conf = config(prefix)
    prepare_receipt = load(output(prefix, 'PREPARED'))
    require(prepare_receipt['sequence_sha256'] == sha(output(prefix,'SEQUENCE')), 'Prepared sequence changed')
    require(conf['schema'] == 'stage9-controlled-release-v2' and conf['prefix'] == prefix, 'Unexpected Release sequence')
    require(conf['ordered_phases'] == PHASES, 'Unexpected Release phase order')
    arm_path, fat_path = retained_paths(prefix)
    require(conf.get('retained_arm_path') == str(arm_path) and
            conf.get('universal_temporary_path') == str(fat_path), 'Retained slice path binding mismatch')
    require(Path(budget_path).resolve() == Path(conf['budget']), 'Budget path differs from prepared input')
    for name, fingerprint in conf['fingerprints'].items():
        path = Path(name)
        require(path.is_file() and sha(path) == fingerprint, 'Prepared input changed: ' + name)
    require(conf['source_manifest_sha256'] == sha(Path(conf['source_manifest_to_bind_at_execution'])), 'Source manifest changed')
    monitored.read_budget(Path(conf['budget']), release=True, source_sha=conf['source_manifest_sha256'])
    for phase in PHASES:
        expected = [conf['python'], str(Path(__file__).resolve()), phase.lower().replace('_','-'),
                    '--prefix', prefix, '--budget', conf['budget']]
        require(load(output(prefix,phase+'_COMMAND')) == expected, 'Phase bypasses controlled dispatcher: ' + phase)
    return conf

def monitor_identity(prefix, phase, conf):
    require(phase in PHASES, 'Unknown phase')
    return {'prefix':prefix, 'phase':phase, 'sequence_sha256':sha(output(prefix,'SEQUENCE')),
            'prepare_receipt_sha256':sha(output(prefix,'PREPARED')),
            'source_manifest_sha256':conf['source_manifest_sha256'], 'fingerprints':conf['fingerprints']}

def binding(prefix):
    conf = config(prefix)
    prepared(prefix, Path(conf['budget']))
    item = load(output(prefix, 'BINDING'))
    current = source_identity(Path(item['source']['manifest_path']))
    require(current == item['source'], 'Source/manifest changed after Release binding')
    require(verify_contract() == item['contract'], 'Contract changed after Release binding')
    require(item['sequence_sha256'] == sha(output(prefix,'SEQUENCE')), 'Binding/sequence changed')
    require(item['fingerprints'] == conf['fingerprints'], 'Bound tooling/budget/commands changed')
    return item

def preceding_receipts(prefix, phase, conf):
    """Result files alone never authorize the next consumer."""
    limits = monitored.read_budget(Path(conf['budget']), release=True, source_sha=conf['source_manifest_sha256'])
    prior = []
    for previous in PHASES[:PHASES.index(phase)]:
        execution_path = output(prefix,previous+'_EXECUTION')
        execution = load(execution_path)
        require(monitored.execution_succeeded(execution, limits), 'Previous monitored phase failed/incomplete: ' + previous)
        cmd = output(prefix,previous+'_COMMAND')
        require(execution.get('command') == load(cmd) and execution.get('command_sha256') == sha(cmd), 'Previous command binding mismatch: ' + previous)
        require(execution.get('release') == monitor_identity(prefix,previous,conf), 'Previous Release identity mismatch: ' + previous)
        receipt_path = output(prefix,previous+'_PHASE_RECEIPT')
        require(execution.get('phase_receipt_sha256') == sha(receipt_path), 'Previous phase receipt changed: ' + previous)
        receipt = load(receipt_path)
        require(receipt['phase'] == previous and receipt['provenance']['predecessor_receipts'] == prior,
                'Previous receipt chain mismatch: ' + previous)
        require(receipt['provenance']['source_manifest_sha256'] == conf['source_manifest_sha256'], 'Previous source identity mismatch')
        require(receipt['binding_sha256'] == sha(output(prefix,'BINDING')) == execution.get('binding_sha256'), 'Previous binding changed')
        for name, fingerprint in receipt['artifacts'].items():
            require(sha(Path(name)) == fingerprint, 'Previous phase artifact changed: ' + name)
        prior.append({'phase':previous,'execution_sha256':sha(execution_path),'phase_receipt_sha256':sha(receipt_path)})
    return prior

def monitor_context(prefix, phase, conf):
    path = Path(os.environ.get('STAGE9_MONITOR_RECEIPT',''))
    require(path == output(prefix,phase+'_EXECUTION'), 'Phase must be launched by its controlled monitor')
    result = load(path)
    require(result.get('nonce') == os.environ.get('STAGE9_MONITOR_NONCE') and result.get('monitor_pid') == os.getppid(),
            'Monitor parent/nonce mismatch')
    require(result.get('state') == 'running', 'Monitor is not running')
    require(result.get('release') == monitor_identity(prefix,phase,conf), 'Monitor Release identity mismatch')
    command_path = output(prefix,phase+'_COMMAND')
    require(result.get('command') == load(command_path) and result.get('command_sha256') == sha(command_path), 'Monitor command mismatch')
    require(result.get('budget_sha256') == sha(Path(conf['budget'])), 'Monitor budget mismatch')
    return {'monitor_receipt_path':str(path),'monitor_nonce':result['nonce']}

def save_bound(prefix, label, value, provenance):
    save(output(prefix,label), dict(value, provenance=provenance))

def build_succeeded(prefix, arch):
    # Dispatcher has already checked the complete monitored predecessor chain.
    result = load(output(prefix, f'{arch.upper()}_EXECUTION'))
    conf = config(prefix)
    limits = monitored.read_budget(Path(conf['budget']), release=True, source_sha=conf['source_manifest_sha256'])
    require(monitored.execution_succeeded(result,limits), f'{arch} monitored build did not finish successfully')
    expected = load(output(prefix, f'{arch.upper()}_COMMAND'))
    require(result.get('command') == expected, 'Build execution/argv mismatch')
    log = ROOT / f'STAGE9_{prefix}_{arch.upper()}.log'
    text = log.read_text()
    require('** BUILD SUCCEEDED **' in text, 'Missing successful build action marker')
    require(not re.search(r'(?m)^CodeSign\s', text), 'Unexpected app code-sign operation')
    require(not re.search(r'(?:-D\s*|SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*)(?:DEBUG|STAGE9_ISOLATED_TEST_BUILD)\b',text), 'Unexpected DEBUG compilation flag')
    return {'execution_sha256':sha(output(prefix,f'{arch.upper()}_EXECUTION')),'log_sha256':sha(log)}

def inspect_files():
    require(APP.is_dir() and not APP.is_symlink(), 'Expected standalone app directory')
    entries = {}; macho = []
    for path in sorted(APP.rglob('*')):
        name = str(path.relative_to(APP))
        require(not any(part.endswith(('.xctest','.appex')) or 'UITests-Runner' in part for part in path.parts), 'Unexpected test/extension product')
        if path.is_symlink():
            require(path.resolve().is_relative_to(APP.resolve()), f'Escaping app symlink: {name}')
            entries[name] = {'type':'symlink','target':os.readlink(path)}
            continue
        if not path.is_file(): continue
        data = path.read_bytes()
        entries[name] = {'type':'file','bytes':len(data),'sha256':digest_bytes(data),'mode':stat.S_IMODE(path.stat().st_mode)}
        if data[:4] in MAGICS: macho.append(path)
        require(path.suffix.lower() not in {'.html','.htm','.js','.mjs','.wasm'}, f'Unexpected web runtime asset: {name}')
    require(EXE in macho, 'Main executable not recognized as Mach-O')
    plist = plistlib.loads((APP/'Contents/Info.plist').read_bytes())
    require(plist.get('CFBundleExecutable') == 'IncomeClock', 'Unexpected main executable')
    require(plist.get('CFBundleIdentifier') == 'com.ffq.incomeclock', 'Unexpected bundle identifier')
    require(plist.get('LSMinimumSystemVersion') == '13.0', 'Bundle minimum system version differs')
    require(plist.get('LSUIElement') is True, 'Missing agent declaration')
    return entries, macho, plist

def version(value):
    values = tuple(int(x) for x in value.split('.'))
    return (values+(0,0,0))[:3]

def binary_details(path, required_arches, *, main_executable=False):
    arches_run = command(['xcrun','lipo','-archs',str(path)])
    arches = arches_run['stdout'].strip().split()
    require(set(arches) == set(required_arches) and len(arches) == len(set(arches)), f'Unexpected architecture set {path}: {arches}')
    slices=[]
    for arch in arches:
        build = command(['xcrun','vtool','-arch',arch,'-show-build',str(path)])
        platform = re.findall(r'^\s*platform\s+(\S+)',build['stdout'],re.M)
        minimum = re.findall(r'^\s*minos\s+(\S+)',build['stdout'],re.M)
        if not minimum and 'LC_VERSION_MIN_MACOSX' in build['stdout']:
            minimum = re.findall(r'^\s*version\s+(\S+)',build['stdout'],re.M);platform=['MACOS']
        require(platform == ['MACOS'] and len(minimum)==1, f'Missing/unexpected platform load command: {path}/{arch}')
        require(version(minimum[0]) <= (13,0,0), f'Embedded Mach-O requires later macOS: {path}/{arch}')
        if main_executable or path == EXE or path == FAT or path == ARM:
            require(version(minimum[0]) == (13,0,0), 'Main executable minimum must equal13.0')
        links = command(['xcrun','otool','-arch',arch,'-L',str(path)])
        dependencies=[line.strip().split(' (compatibility version',1)[0] for line in links['stdout'].splitlines() if line.startswith('\t')]
        require(not any(any(token in dep for token in ['XCTest','WebKit','JavaScriptCore','Electron','Tauri']) for dep in dependencies), 'Unexpected test/web runtime dependency')
        for dep in dependencies:
            if dep.startswith(('/System/Library/','/usr/lib/')): continue
            if dep.startswith('@rpath/'):
                resolved=APP/'Contents/Frameworks'/dep[len('@rpath/'):]
            elif dep.startswith('@executable_path/'):
                resolved=EXE.parent/dep[len('@executable_path/'):]
            elif dep.startswith('@loader_path/'):
                resolved=path.parent/dep[len('@loader_path/'):]
            else: raise RuntimeError(f'Unexpected absolute/custom dylib dependency {dep}')
            require(resolved.is_file() and resolved.resolve().is_relative_to(APP.resolve()), f'Unresolved embedded dependency {dep}')
        slices.append({'arch':arch,'minimum_macos':minimum[0],'build_command':build,'dependencies_command':links})
    strings = command(['strings','-a',str(path)])
    symbols = command(['xcrun','nm','-a',str(path)],allowed=(0,1))
    require(symbols['exit']==0 or 'no symbols' in symbols['stderr'].lower(), 'Symbol inspection failed')
    demangled = subprocess.run(['xcrun','swift-demangle'],input=symbols['stdout'].encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
    require(demangled.returncode==0, 'Demangle failed')
    symbol_text=demangled.stdout.decode(errors='replace')
    hits=[token for token in TOKENS if token in strings['stdout'] or token in symbol_text]
    require(not hits, f'App debug/test entry strings or symbols found: {path}: {hits}')
    return {'path':str(path),'sha256':sha(path),'arch_command':arches_run,'slices':slices,
            'strings_scan':{'argv':strings['argv'],'stdout_sha256':strings['stdout_sha256'],'lines':len(strings['stdout'].splitlines()),'tokens':TOKENS,'hits':hits},
            'symbol_scan':{'argv':symbols['argv'],'exit':symbols['exit'],'stdout_sha256':symbols['stdout_sha256'],'demangled_sha256':digest_bytes(demangled.stdout),'debug_hits':hits},
            'limits':'Token/symbol scan is supporting evidence; compile conditions and exact source binding provide the other boundary. FixedClock value type is not itself forbidden; Release assembly must use SystemClock.'}

def settings_check(prefix,provenance):
    binding(prefix)
    result=load(output(prefix,'SETTINGS_EXECUTION'))
    limits=monitored.read_budget(Path(config(prefix)['budget']),release=True,source_sha=config(prefix)['source_manifest_sha256'])
    require(monitored.execution_succeeded(result,limits),'Settings monitored query failed')
    require(result.get('command')==load(output(prefix,'SETTINGS_COMMAND')),'Settings argv mismatch')
    log=ROOT/f'STAGE9_{prefix}_SETTINGS.log'; text=log.read_text(); parsed=None
    for match in re.finditer(r'\[',text):
        try: candidate,_=json.JSONDecoder().raw_decode(text[match.start():])
        except json.JSONDecodeError: continue
        if isinstance(candidate,list) and candidate and all(isinstance(x,dict) and 'buildSettings' in x for x in candidate): parsed=candidate;break
    require(parsed is not None,'No complete settings JSON found')
    app=[x for x in parsed if x.get('target')=='IncomeClock']; require(len(app)==1,'Expected one app settings entry')
    values=app[0]['buildSettings']
    for key,expected in {'CONFIGURATION':'Release','MACOSX_DEPLOYMENT_TARGET':'13.0','ENABLE_HARDENED_RUNTIME':'YES','CODE_SIGNING_ALLOWED':'NO','CODE_SIGNING_REQUIRED':'NO'}.items():
        require(values.get(key)==expected,f'Unexpected effective setting {key}={values.get(key)}')
    require(set(values.get('ARCHS','').split())=={'arm64','x86_64'},'Unexpected effective architectures')
    require(values.get('ENABLE_TESTABILITY','NO')!='YES','Release testability enabled')
    require(values.get('CODE_SIGN_IDENTITY','')=='','Unexpected signing identity')
    for key in ['SWIFT_ACTIVE_COMPILATION_CONDITIONS','OTHER_SWIFT_FLAGS','GCC_PREPROCESSOR_DEFINITIONS']:
        require(not re.search(r'\b(DEBUG|STAGE9_ISOLATED_TEST_BUILD)\b',values.get(key,'')),f'Debug/test condition in {key}')
    entitlement=Path(values.get('CODE_SIGN_ENTITLEMENTS','')); entitlement=entitlement if entitlement.is_absolute() else ROOT/entitlement
    require(entitlement.resolve()==(ROOT/'IncomeClock/Resources/IncomeClock.entitlements').resolve(),'Unexpected entitlement source')
    require(plistlib.loads(entitlement.read_bytes())=={'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True},'Unexpected production entitlement declaration')
    selected={k:values.get(k) for k in ['CONFIGURATION','ARCHS','ONLY_ACTIVE_ARCH','MACOSX_DEPLOYMENT_TARGET','SWIFT_OPTIMIZATION_LEVEL','ENABLE_HARDENED_RUNTIME','CODE_SIGN_ENTITLEMENTS','CODE_SIGNING_ALLOWED','CODE_SIGNING_REQUIRED','CODE_SIGN_IDENTITY','ENABLE_TESTABILITY','SWIFT_ACTIVE_COMPILATION_CONDITIONS','OTHER_SWIFT_FLAGS','GCC_PREPROCESSOR_DEFINITIONS','TARGET_BUILD_DIR','FULL_PRODUCT_NAME']}
    require(Path(values['TARGET_BUILD_DIR']).resolve()==PRODUCTS.resolve(),'Unexpected Release product root')
    save_bound(prefix,'SETTINGS_VERIFIED',{'effective_settings':selected,'settings_log_sha256':sha(log),'entitlements_sha256':sha(entitlement),'limits':'Source/effective configuration declarations only; unsigned app does not prove sandbox or hardened runtime enforcement.'},provenance)

def prepare(prefix, manifest, budget_path):
    require(re.fullmatch(r'[A-Z][A-Z0-9_]{0,40}',prefix),'Use a short uppercase run prefix')
    require(budget_path is not None, 'prepare requires an explicit fresh --budget')
    arm_path, fat_path = retained_paths(prefix)
    require_new_retained_target(arm_path)
    require_new_retained_target(fat_path)
    manifest = manifest.resolve(strict=True)
    budget_path = budget_path.resolve(strict=True)
    source = source_identity(manifest)
    monitored.read_budget(budget_path, release=True, source_sha=source['manifest_sha256'])
    plan_path = ROOT/'STAGE9_RELEASE_ARTIFACT_PLAN.json'
    plan = load(plan_path)
    actions = {'SETTINGS':plan['commands']['show_release_settings_argv']}
    for arch in ['arm64','x86_64']:
        argv = list(plan['commands'][arch+'_build_argv'])
        argv[argv.index('-resultBundlePath')+1] = str(RUN/'Results'/f'{prefix}{arch}.xcresult')
        actions[arch.upper()] = argv
    commands = {phase:[sys.executable,str(Path(__file__).resolve()),phase.lower().replace('_','-'),
                       '--prefix',prefix,'--budget',str(budget_path)] for phase in PHASES}
    targets = [output(prefix,name) for name in ['SEQUENCE','PREPARED','BINDING']]
    targets += [output(prefix,phase+suffix) for phase in PHASES for suffix in ['_COMMAND','_EXECUTION','_PHASE_RECEIPT']]
    targets += [ROOT/f'STAGE9_{prefix}_{phase}.log' for phase in PHASES]
    require(not any(p.exists() for p in targets),'Prefix already has artifacts; preserve them and choose a new prefix')
    for phase,argv in commands.items(): save(output(prefix,phase+'_COMMAND'),argv)
    inputs = [Path(__file__).resolve(),ROOT/'scripts/stage9_run_monitored.py',ROOT/'scripts/stage9_artifact_monitor.py',
              budget_path,manifest,plan_path]+[output(prefix,phase+'_COMMAND') for phase in PHASES]
    conf = {'schema':'stage9-controlled-release-v2','prefix':prefix,'state':'PREPARED_NOT_EXECUTED',
            'source_manifest_to_bind_at_execution':str(manifest),'source_manifest_sha256':source['manifest_sha256'],
            'python':sys.executable,'budget':str(budget_path),'sole_derived_data':str(DD),'ordered_phases':PHASES,
            'retained_arm_path':str(arm_path),'universal_temporary_path':str(fat_path),
            'fingerprints':{str(p):sha(p) for p in inputs},'actions':actions,
            'run_with_existing_monitor':[[sys.executable,str(ROOT/'scripts/stage9_run_monitored.py'),prefix+'_'+phase,
                str(output(prefix,phase+'_COMMAND')),'--budget',str(budget_path),'--release-prefix',prefix,'--phase',phase] for phase in PHASES],
            'manual_between_architecture_gate':'Root coordinator must read-only inventory actual cumulative/root/DD usage and assess remaining reserve before each slice. No automatic budget decrement or accurate peak prediction is claimed. Exact authorized idle cache disposition only; no cleanup by this script.',
            'limitations':['No app launch/signing/notarization/distribution','All phases require monitor parent handshake and successful monitored predecessor chain','Budget estimates cannot enlarge authorized caps; source/tooling/commands/budget remain pinned for the whole sequence']}
    save(output(prefix,'SEQUENCE'),conf)
    save(output(prefix,'PREPARED'),{'sequence_sha256':sha(output(prefix,'SEQUENCE')),
         'source_manifest_sha256':source['manifest_sha256'],'fingerprints':conf['fingerprints'],
         'state':'PREPARED_NOT_EXECUTED'})


def execute_phase(prefix, phase, identity, provenance, conf):
    arm_path, fat_path = retained_paths(prefix)
    require(conf.get("retained_arm_path") == str(arm_path) and
            conf.get("universal_temporary_path") == str(fat_path), "Retained slice path binding mismatch")
    if phase == 'BIND':
        source = source_identity(Path(conf['source_manifest_to_bind_at_execution']))
        save_bound(prefix,'BINDING',{'source':source,'contract':verify_contract(),
            'sequence_sha256':sha(output(prefix,'SEQUENCE')),'fingerprints':conf['fingerprints'],
            'environment':{'xcode':command(['xcodebuild','-version']),'sdk':command(['xcrun','--sdk','macosx','--show-sdk-version']),
                           'host':command(['sw_vers']),'arch':command(['uname','-m'])},
            'scope':'Internal unsigned Release static verification only; no launch.'},provenance)
        return
    if phase in conf['actions']:
        argv = conf['actions'][phase]
        # Inherit monitored stdout/stderr, preserving original xcodebuild JSON or
        # BUILD SUCCEEDED marker in the one phase log. Never expose a raw build
        # as a prepared top-level command that skips dispatcher gates.
        done = subprocess.run(argv,cwd=ROOT,check=False)
        require(done.returncode == 0, f'{phase} action failed ({done.returncode})')
        save_bound(prefix,phase+'_ACTION',{'argv':argv,'exit':done.returncode},provenance)
        return
    if phase == 'SETTINGS_CHECK':
        settings_check(prefix,provenance)
        return
    require(output(prefix,'SETTINGS_VERIFIED').is_file(),'Effective settings must be verified first')
    if phase.startswith('INSPECT_'):
        arch=phase[len('INSPECT_'):].lower(); producer=build_succeeded(prefix,arch)
        files,macho,plist=inspect_files()
        # Current product has a single statically-linked executable. A new nested
        # Mach-O needs an explicit per-file slice recipe, never silent thin shipping.
        require(macho==[EXE],'Nested Mach-O found: stop and extend explicit slice preservation plan')
        details=[binary_details(path,[arch]) for path in macho]
        resource_map={k:v for k,v in files.items() if k!='Contents/MacOS/IncomeClock'}
        if arch=='arm64':
            require_new_retained_target(arm_path)
            with EXE.open('rb') as source, arm_path.open('xb') as target: shutil.copyfileobj(source,target)
            os.chmod(arm_path,stat.S_IMODE(EXE.stat().st_mode))
            require(sha(arm_path)==sha(EXE),'Thin copy fingerprint mismatch')
        else:
            arm=load(output(prefix,'ARM64_INSPECTION'))
            require(arm['resources']==resource_map,'Resources changed between architecture builds')
            require(sha(arm_path)==arm['main_sha256'],'Preserved arm64 binary changed')
        binding(prefix)
        save_bound(prefix,arch.upper()+'_INSPECTION',{'source_manifest_sha256':identity['source']['manifest_sha256'],'producer':producer,'files':files,'resources':resource_map,'plist':plist,'mach_o':details,'main_sha256':sha(EXE),'signature_observation':command(['codesign','-d','--verbose=4',str(APP)],allowed=(0,1)),'scope':'Thin internal candidate, not final delivery'},provenance);return
    if phase=='ASSEMBLE':
        arm=load(output(prefix,'ARM64_INSPECTION'));intel=load(output(prefix,'X86_64_INSPECTION'))
        require(sha(arm_path)==arm['main_sha256'] and sha(EXE)==intel['main_sha256'],'Thin input changed')
        require(arm['resources']==intel['resources'],'Resource maps disagree')
        require_new_retained_target(fat_path)
        merged=command(['xcrun','lipo','-create',str(arm_path),str(EXE),'-output',str(fat_path)])
        details=binary_details(fat_path,['arm64','x86_64'],main_executable=True)
        # lipo is a container operation: compare every original slice byte via
        # in-memory fat-table offsets, without copying more large binaries.
        import struct
        data=fat_path.read_bytes();require(data[:4]==bytes.fromhex('cafebabe'),'Expected standard fat header')
        count=struct.unpack_from('>I',data,4)[0]; slices={}
        for i in range(count):
            cpu,subtype,offset,length,alignment=struct.unpack_from('>IIIII',data,8+20*i)
            require(offset+length<=len(data),'Truncated fat slice')
            slices[cpu]=digest_bytes(data[offset:offset+length])
        require(slices=={0x100000c:arm['main_sha256'],0x1000007:intel['main_sha256']},'Combined slice bytes differ')
        binding(prefix); os.chmod(fat_path,stat.S_IMODE(EXE.stat().st_mode)); os.replace(fat_path,EXE)
        save_bound(prefix,'ASSEMBLED',{'command':merged,'universal_sha256':sha(EXE),'slice_sha256':slices,'pre_replace_details':details,'scope':'Internal unsigned universal app; no final human acceptance or deployment','retained_thin_path':str(arm_path),'cleanup':'No cleanup performed; thin temporary remains pending exact authorized disposition'},provenance);return
    require(phase=='VERIFY','Unexpected phase')
    assembled=load(output(prefix,'ASSEMBLED'));require(sha(EXE)==assembled['universal_sha256'],'Assembled executable changed')
    files,macho,plist=inspect_files(); details=[binary_details(path,['arm64','x86_64']) for path in macho]
    arm=load(output(prefix,'ARM64_INSPECTION'))
    require({k:v for k,v in files.items() if k!='Contents/MacOS/IncomeClock'}==arm['resources'],'Final resources drifted')
    signature=command(['codesign','-d','--verbose=4',str(APP)],allowed=(0,1))
    require(not re.search(r'Authority=|TeamIdentifier=(?!not set)',signature['stderr']),'Unexpected signing identity')
    binding(prefix)
    save_bound(prefix,'FINAL_VERIFICATION',{'classification':'UNSIGNED_RELEASE_TECHNICAL_EVIDENCE_CANDIDATE','source_manifest_sha256':identity['source']['manifest_sha256'],'app_path':str(APP),'files':files,'mach_o':details,'plist':plist,'signature':signature,'source_entitlement_sha256':sha(ROOT/'IncomeClock/Resources/IncomeClock.entitlements'),'settings_evidence_sha256':sha(output(prefix,'SETTINGS_VERIFIED')),'limitations':['All package Mach-O inspected; both main slices minOS13; no app launch on either architecture or macOS13.','Unsigned app: sandbox/hardened declarations only, not signature-backed enforcement. Linker-generated ad-hoc Mach-O signatures may exist and are not distribution signing.','No notarization/Gatekeeper/real permission/offline runtime/physical display/final human acceptance/deployment claims.','Actual SystemClock assembly is bound by reviewed AppDelegate source and no DEBUG compile conditions, supported by final binary token/symbol scans.','App remains at its exact DD producer path and is not an immutable sealed input; final human/independent review must bind any separately selected minimal deliverable.'],'final_human_acceptance':'PENDING','deployment_authorization':'NOT_AUTHORIZED','independent_review':'AWAITING_INDEPENDENT_REVIEW'},provenance)


def dispatch(prefix, phase, budget_path):
    conf = prepared(prefix,budget_path)
    context = monitor_context(prefix,phase,conf)
    assert_idle()
    # Check live source even for BIND; later phases also recheck Contract/binding.
    source = source_identity(Path(conf['source_manifest_to_bind_at_execution']))
    require(source['manifest_sha256'] == conf['source_manifest_sha256'], 'Source changed before phase')
    prior = preceding_receipts(prefix,phase,conf)
    identity = None if phase == 'BIND' else binding(prefix)
    provenance = dict(context,phase=phase,source_manifest_sha256=conf['source_manifest_sha256'],
        sequence_sha256=sha(output(prefix,'SEQUENCE')),budget_sha256=sha(Path(conf['budget'])),
        binding_sha256=None if phase=='BIND' else sha(output(prefix,'BINDING')),
        predecessor_receipts=prior,command_sha256=sha(output(prefix,phase+'_COMMAND')),
        fingerprints=conf['fingerprints'])
    execute_phase(prefix,phase,identity,provenance,conf)
    prepared(prefix,budget_path)
    binding(prefix)
    require(preceding_receipts(prefix,phase,conf) == prior, 'Predecessor receipts changed during phase')
    artifact = output(prefix,PHASE_OUTPUTS[phase])
    require(artifact.is_file(), 'Expected phase artifact absent')
    save(output(prefix,phase+'_PHASE_RECEIPT'),{'phase':phase,'provenance':provenance,
        'binding_sha256':sha(output(prefix,'BINDING')),'artifacts':{str(artifact):sha(artifact)},
        'scope':'Dispatcher completed; next consumer additionally requires successful monitor exit and after inventory.'})


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=['prepare']+[p.lower().replace('_','-') for p in PHASES])
    parser.add_argument('--prefix',default='RELEASE')
    parser.add_argument('--source-manifest',type=Path,default=ROOT/'STAGE9_CLOSEOUT_PENDING_MANIFEST.json')
    parser.add_argument('--budget',type=Path,required=True)
    args=parser.parse_args(argv)
    require(re.fullmatch(r'[A-Z][A-Z0-9_]{0,40}',args.prefix),'Invalid prefix')
    if args.phase=='prepare':
        prepare(args.prefix,args.source_manifest,args.budget)
        print('Prepared only; no build/app/cache action.')
    else:
        dispatch(args.prefix,args.phase.upper().replace('-','_'),args.budget)
    return 0


if __name__=='__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error),file=sys.stderr)
        raise SystemExit(1)
