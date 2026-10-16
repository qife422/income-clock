#!/usr/bin/env python3
"""Read-only inputs; small developer observation candidate, never acceptance PASS."""
import csv, hashlib, json, plistlib, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p): return (ROOT / p).read_text()
def rows(p): return list(csv.DictReader(p.open(), delimiter='\t'))
def write(p, value):
    assert not p.exists(), f'preserve existing observation: {p}'
    p.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

project = 'IncomeClock.xcodeproj/project.pbxproj'
pin = 'IncomeClock.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / project)]))['objects']
file_paths = {}
main = next(k for k,v in objects.items() if v.get('isa') == 'PBXGroup' and not v.get('path') and not v.get('name'))
def walk(key, parent):
    obj = objects[key]
    path = parent / obj.get('path', '')
    if obj.get('isa') == 'PBXGroup':
        for child in obj.get('children', []): walk(child, path)
    else: file_paths[key] = path.as_posix()
walk(main, Path('.'))
target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'IncomeClock')
source = []; resources = []; phases = []
for phase_id in target['buildPhases']:
    phase = objects[phase_id]; phases.append(phase['isa'])
    for build_id in phase.get('files', []):
        build = objects[build_id]
        if 'fileRef' not in build: continue
        path = file_paths[build['fileRef']]
        if phase['isa'] == 'PBXSourcesBuildPhase': source.append(path)
        elif phase['isa'] == 'PBXResourcesBuildPhase':
            p = ROOT / path
            resources += [str(f.relative_to(ROOT)) for f in p.rglob('*') if f.is_file()] if p.is_dir() else [path]
source.sort(); resources.sort()
assert len(source) == len(set(source)) == 34
closed = source + resources + [project, pin, 'IncomeClock/Resources/Info.plist', 'IncomeClock/Resources/IncomeClock.entitlements']
business = [p for p in source if '/Domain/' in p or p.endswith(('BusinessStore.swift','BusinessStoreModels.swift','PersistenceRecords.swift'))]
theme = [p for p in source if '/Theme/' in p or '/Theme' in p]
repo = 'IncomeClock/Infrastructure/Theme/ThemeRepository.swift'
validation = 'IncomeClock/Infrastructure/Theme/ThemePackageValidation.swift'
models = 'IncomeClock/Application/ThemeModels.swift'
profile = 'IncomeClock/Presentation/Panel/PanelPresentationProfile.swift'
settings = 'IncomeClock/Presentation/Settings/EmptySettingsView.swift'
menu = 'IncomeClock/Presentation/MenuBar/MenuBarContentView.swift'
panel = 'IncomeClock/Presentation/Panel/EmptyPanelView.swift'
stage8 = 'IncomeClockApplicationTests/Stage8ThemeImportTests.swift'
docs = ['SPEC.md','UI_SPEC.md','TECH_SPEC.md','AGENTS.md','SPEC_GOVERNANCE.md','DEVELOPMENT_STATE.md','SPEC_INDEX.md','STAGE4_REVIEW.md','STAGE4_REPORT.md','STAGE4D_S4DR006_REREVIEW.md','STAGE5_S5R004_UI_EVIDENCE_RECHECK.md','STAGE9_SYSTEM_GATES.md','README.md','STAGE9_CLOSEOUT_STATIC_REVIEW.md','STAGE9_CLOSEOUT_REMAINING_PREDICATES.tsv','STAGE9_CLOSEOUT_DISPOSITION.tsv']
package = Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/SourcePackages/checkouts/ZIPFoundation')
package_sources = sorted(package.glob('Sources/**/*.swift')) + [package/'Package.swift']
inputs = sorted(set(closed + docs + [stage8,'STAGE9_CLOSEOUT_THEME_VALIDATOR_CLOSURE.tsv', 'IncomeClockApplicationTests/PanelTests.swift']))
fingerprints = {p:sha(ROOT/p) for p in inputs}
groups = {
 'native': closed,
 'copy': source + [p for p in resources if Path(p).suffix in ['.json','.txt','.strings','.stringsdict','.xcstrings']],
 'theme': theme + [settings,stage8],
 'profile': business + [profile,'IncomeClock/App/AppEnvironment.swift','IncomeClock/Presentation/Panel/PanelController.swift'],
 'validators': [validation,repo,models,'IncomeClock/Application/ThemeImportModels.swift','STAGE9_CLOSEOUT_THEME_VALIDATOR_CLOSURE.tsv'],
 'governance': ['SPEC.md','UI_SPEC.md','TECH_SPEC.md','SPEC_GOVERNANCE.md','DEVELOPMENT_STATE.md','SPEC_INDEX.md','STAGE4_REVIEW.md','STAGE4D_S4DR006_REREVIEW.md','STAGE5_S5R004_UI_EVIDENCE_RECHECK.md','STAGE9_SYSTEM_GATES.md'],
 'menu': [menu], 'notes': ['README.md'], 'checklist': ['STAGE9_CLOSEOUT_DISPOSITION.tsv'],
 'notifications': ['IncomeClock/Infrastructure/Notifications/UNUserNotificationCenterService.swift','IncomeClock/Resources/IncomeClock.entitlements'] + source,
 'login': ['IncomeClock/Infrastructure/LoginItem/SMAppServiceLoginItemService.swift'] + source,
}
observations = {}
def add(ids, group, observation, limitation, kind='SCOPED_STATIC_OBSERVATION'):
    for rid in ids.split(): observations[rid] = dict(group=group, observation=observation, limitation=limitation, candidate_kind=kind)

add('P21-002.a','native','PBX application target closes to 34 explicitly compiled Swift files, three resource references, ZIPFoundation package product, and no script build phase. Native entry is SwiftUI MenuBarExtra/Settings and AppKit NSPanel; no web runtime import/asset/package found. ZIPFoundation manifest uses ZIPFoundation + system Compression/CZLib, no package dependency.','Actual final Release bundle, linked dylibs and nested executable inventory remain separate; static graph is not offline runtime evidence.')
add('P21-003.a','native','Production source Info.plist declares LSUIElement=true; native menu-bar entry contains no regular activation-policy override.','Default Dock behavior requires actual production app launch; source plist is not final bundle or system runtime.')
add('P21-004.a','native','Compiled app graph contains no WidgetKit import or extension product; amount view is SwiftUI/AppKit and uses native amount layers.','Final bundle extension inventory and current amount runtime binding remain separate.')
add('P21-025.a P22-037.a','copy','Inspected all compiled source string-bearing lines, CJK literals and bundled JSON/text input inventory, including App commands, notification body, ThemeStore/model diagnostics, menu, panel, seven Settings pages and accessibility text. No application-authored wage-rate wording found; user-visible amounts are accumulated/estimated/settled with duration/countdown.','Indexed quoted/CJK lines plus complete file SHA support re-extraction, not a Swift AST/localization compiler. Dynamic Theme name/description/path/diagnostic item are external text displayed verbatim; arbitrary external copy is outside this application-authored observation. Strings absence alone is not exhaustive runtime conformance.','COPY_AUDIT_CANDIDATE')
add('P21-102.a T-050.a','theme','Theme ingestion copies a security-scoped selected ZIP into bounded staging, parses JSON against key whitelist/remote-reference rejection, forbids executable/link entries and code/plugin/archive extensions, verifies hashes and decodes ImageIO/AVFoundation media. Runtime manifest maps only approved static semantic state decorations; no eval/process/network loader in compiled Theme closure.','Closed call-path inspection and forbidden-API scan are supporting static evidence; do not claim whole-app runtime no-network or all adversarial behavior. Dedicated DEBUG AppDelegate process harness is outside Theme production call closure.')
add('P21-104.a P22-060.a','theme','validateCompatibility accepts required standard-theme@1 only; ignoredOptionalCapabilities lists every other capability; default registry contains only standard and makeRuntimeManifest ignores future profile/mask fields. Existing sound event data does not advertise sound-pack.','Does not claim future capabilities implemented or all runtime downgrade predicates verified.')
add('P21-105.a P22-061.a','theme','Rejection occurs before payload extraction/install. Candidate counterexample: capability.required exposes name but omits requested numeric version/minimum app; app.version exposes generic minimumAppVersion key but not the required/current values; profile diagnostics omit rejected profile ID. Settings renders/copies only diagnostic fields, so cannot reconstruct missing values. SPEC §20 requires explicit requested/current/minimum information.','Existing corpus asserts diagnostic codes/rejection, not all required text. Separate reviewer confirmed S9C006 P2 OPEN; this report neither repairs nor closes it. Need exact rendered/copy diagnostics and no Themes writes evidence.','POTENTIAL_COUNTEREXAMPLE_AWAITS_REVIEW')
add('P22-063.a','theme','Optional mask requires shaped-panel plus standard panel fallback; mask still passes path/hash/media validation but makeRuntimeManifest maps only state.* resources. Existing named optional-profile test asserts no mask decoration before/after install+reload and rejects invalid fallback/mask.','This static source audit does not itself rerun the named test or prove complete Business and hit-region equality. Runtime binding remains required.','PARTIAL_STATIC_AND_TEST_SOURCE')
add('P21-109.a UI18-004.a','profile','PanelPresentationProfile.standard owns 320x190/safe-area/drag/default-edge constants. Compiled Domain + BusinessStore/Models + authority PersistenceRecords do not read Profile or registry; PanelController receives Profile on presentation side.','Dependency-direction declaration only; no claim arbitrary Profile changes preserve every business output at runtime.')
add('P22-064.a','profile','Production dependency direction has no Business/record input from Profile. Existing theme lifecycle tests preserve complete Business trajectories for theme changes, while located Profile tests exercise geometry.','No located test changes standard Profile configuration and directly compares full Store/state/timestamps/notifications/persistence/amount tuple with identical business inputs; theme switching is not equivalent to this predicate.','RUNTIME_PREDICATE_GAP')
add('P23-08.a','notes','README data/time section explicitly describes local application-container data, device-clock/timezone influence, and macOS notification nondelivery limits.','Document-content observation only; no assertion of runtime persistence or real notification delivery.')
add('T-008.a','validators','Path/token/schema/diagnostic/SemanticVersion/compatibility value closure inspected. Compatibility reads immutable configured currentAppVersion; no actual UI object or I/O inside these specific functions. Whole ThemeRepository contains I/O and is excluded. ThemeModels changed only appearance resolver relative to005; validator nodes are rebound to actual source below.','Do not call entire repository/module pure. ThemeModels Bundle(for:) helper is outside the validator call closure. Old whole-file/fragment hashes cannot be inherited without current rehash.')
add('T-028.a','checklist','Recomputed unique IDs, disjointness and exact set equality: 370 fixed Contract atoms +12 fixed derived gates equal 382 current disposition atoms; source checklist is indexed, not checked-off acceptance.','Structural equality does not verify each atomic requirement meaning or PASS. Historical ledger content/status is not rewritten.')
add('T-029.a UI18-052.a UI18-053.a UI18-055.a','governance','Stage4 review retains S4R003 DEFERRED, full physical matrix pending, no simulated/geometry/single-screen substitute and explicit RC/release prohibition; current governance preserves separate human/system gates.','Can support maintained governance declarations only. Referenced physical matrix remains unverified; no current software or final acceptance inferred.','GOVERNANCE_DECLARATION_CANDIDATE')
add('T-045.deployment_target','native','All project build-setting MACOSX_DEPLOYMENT_TARGET declarations equal13.0.','Actual Release effective settings, binary load commands and macOS13 execution remain unverified.')
add('T-048.a','notifications','Production adapter calls UNUserNotificationCenter.requestAuthorization([.alert,.sound]); source entitlements contain sandbox and user-selected-read-only only. Closed app source has no forbidden Accessibility/screen-recording/automation/location permission request API.','View accessibility modifiers are normal UI exposure, not permission requests. Test infrastructure may use automation permission and is excluded. Actual system grant/deny behavior remains separate.')
add('T-049.a','login','Main-app adapter reads SMAppService.mainApp.status and uses register/unregister; no LaunchAgent/LaunchDaemon installer or launchctl found in compiled app graph.','Source adapter shape only; real registration/readback/login lifecycle remains system gate.')
add('T-051.a','governance','Historical Stage4 review remains review/NOT VERIFIED and last_verified:null with S4R003 deferred. SPEC_GOVERNANCE maps historical mixed statuses into seven independent current axes. No stage-level conditional introduced by this candidate.','Review conclusion CONDITIONALLY_READY in earlier bounded static review is a review axis, not stage Delivery status. Do not rewrite historic fields.','GOVERNANCE_DECLARATION_CANDIDATE')
add('T-052.a','governance','Stage4 review §延期事实 records external-display absence, unknown WindowServer risks, complete real matrix, and no-release conditions; explicitly says deferred is not closed/passed/verified.','Proves recorded deferral metadata, not the missing physical tests.','GOVERNANCE_DECLARATION_CANDIDATE')
add('T-053.a UI18-056.a','governance','PD002 moved S4R003 release ownership without automatic Stage4D/5 implementation authorization; later independent Stage4D record separately documents prior explicit conditional Stage5 authorization activating after seven conditions.','Historical authorization chain only. Does not generate new authorization or waive current gates.','HISTORICAL_CHAIN_CANDIDATE')
add('T-058.automated_single_display','governance','Stage4 review preserves S4R001/002/004/005 CLOSED and S4R003 DEFERRED, with explicit automated/single-display scope.','Historical findings and result records only; no claim current source or current native menu tests inherit those results.','HISTORICAL_CHAIN_CANDIDATE')
add('T-059.a UI18-057.a','governance','Stage4D S4DR006 independent rereview records approved0.8/0.5/0.4, 136/136 historical full regression, delta findings closed, Stage4D verified, then separate seven-condition Stage5 preauthorization activation.','This checks historical record content, not re-execution/readability of all old archived raw inputs. Stage1–3 historical verified is not reused as current delta proof.','HISTORICAL_CHAIN_CANDIDATE')
add('T-060.a','governance','Stage5 S5R004 UI evidence recheck records historical Stage5 verified after targeted menu evidence; previous full delivery report and current Stage9 ongoing UI/software/system gates are distinct.','Current A/B geometry/amount/Reduce Motion/VoiceOver predicates need current coverage. Historical Stage5 verified cannot close all current A UI acceptance.','HISTORICAL_ONLY_CURRENT_RUNTIME_GAP')
add('UI18-005.a','profile','Only standard Profile is registered by default; AppEnvironment/PanelController use standard. Future manifest declarations negotiate fallback, never instantiate shaped/vertical/capsule/HUD layouts.','No future-shape acceptance introduced. Arbitrary injected test profiles are not product-supported profiles.')
add('UI18-035.no_animation_character','menu','Entire MenuBarContentView and helpers use native Text/Button/Toggle/Divider; no character/resource view, TimelineView, withAnimation or product animation producer.','Native menu hover/system behavior is outside this product animation statement; runtime menu order/countdown remain separate.')
add('UI18-054.a','governance','Contract lists real external extended-display/main-secondary/unplug-replug/Dock/resolution-scale/Space-fullscreen/sleep-wake/visibleFrame matrix. Current S4R003 record still lacks physical completion.','This row itself requires actual physical evidence; cannot be converted into static-only conformance or closed by reading the policy.','PHYSICAL_EVIDENCE_REQUIRED')

remaining = [r for r in rows(ROOT/'STAGE9_CLOSEOUT_REMAINING_PREDICATES.tsv') if r['shared_package']=='8-static-provenance-governance']
assert len(remaining)==36 and {r['atomic_requirement_id'] for r in remaining} == set(observations)
ledger = ROOT.parent/'可视收入打卡机_review_inputs/stage9-s9r001-evidence-consistency-repair-2026-08-24-001/Evidence/Ledger'
contracts=rows(ledger/'STAGE9_CONTRACT_REQUIREMENT_COVERAGE_LEDGER.tsv'); gates=rows(ledger/'STAGE9_DERIVED_GATE_LEDGER.tsv'); actual=rows(ROOT/'STAGE9_CLOSEOUT_DISPOSITION.tsv')
cids=[r['sub_requirement_id'] for r in contracts]; gids=[r['gate_id'] for r in gates]; aids=[r['atomic_requirement_id'] for r in actual]
structure={'contract_count':len(cids),'gate_count':len(gids),'actual_count':len(aids),'unique':len(cids)==len(set(cids)) and len(gids)==len(set(gids)) and len(aids)==len(set(aids)),'disjoint':not set(cids)&set(gids),'equal':set(aids)==set(cids)|set(gids),'ledger_sha':{str(p):sha(p) for p in ledger.glob('*.tsv') if p.name in ['STAGE9_CONTRACT_REQUIREMENT_COVERAGE_LEDGER.tsv','STAGE9_DERIVED_GATE_LEDGER.tsv']}}
imports=sorted({m for p in source for m in re.findall(r'^import\s+(\w+)',read(p),re.M)})
copy_index={p:{'sha256':sha(ROOT/p),'quote_or_CJK_line_numbers':[i for i,l in enumerate(read(p).splitlines(),1) if '"' in l or re.search('[\u3400-\u9fff]',l)]} for p in groups['copy']}
forbidden_copy=['工资速度','收入速率','时薪','每小时收入','每分钟收入','每秒收入','¥/h','¥/s','hourly wage','income per second']
copy_hits=[{'file':p,'phrase':term} for p in groups['copy'] for term in forbidden_copy if term.lower() in read(p).lower()]
profile_hits=[{'file':p,'term':t} for p in business for t in ['PanelPresentationProfile','contentSafeArea','primaryDragRegion','standard.panel.320x190','layoutProfile','panelProfile'] if t in read(p)]
forbidden_apis=['URLSession','WKWebView','JavaScriptCore','NSAppleScript','Process(','dlopen(','system(','popen(']
theme_hits=[{'file':p,'term':t} for p in theme for t in forbidden_apis if t in read(p)]
closure=[]
for r in rows(ROOT/'STAGE9_CLOSEOUT_THEME_VALIDATOR_CLOSURE.tsv'):
    p=r['path']; lo=int(r['start_line']); hi=int(r['end_line']); lines=read(p).splitlines(keepends=True)
    if p==models: hi=len(lines)
    closure.append({'node':r['node'],'path':p,'start':lo,'end':hi,'source_sha':sha(ROOT/p),'fragment_sha':hashlib.sha256(''.join(lines[lo-1:hi]).encode()).hexdigest(),'old_file_sha_equal':sha(ROOT/p)==r['source_sha256'],'scope':r['inspected_boundary'],'limitation':r['excluded_claim']})
fixed_path='stage9_closeout_evidence/code-candidate-023/MANIFEST.json'; fixed=json.loads(read(fixed_path))
def line_count(path):
    try: return len(read(path).splitlines())
    except UnicodeDecodeError: return None
bind={p:{'sha256':fingerprints[p],'line_count':line_count(p),'matches_fixed023':fixed.get(p)==fingerprints[p] if p in fixed else None} for p in inputs}
result=[]
for r in remaining:
    obs=observations[r['atomic_requirement_id']]
    result.append({'atomic_requirement_id':r['atomic_requirement_id'],'atomic_requirement':r['atomic_requirement'],**obs,'source_bindings':'; '.join(p+'#'+fingerprints[p] for p in dict.fromkeys(groups[obs['group']])),'method':'python3 scripts/stage9_static_candidate.py; closed PBX graph/value inspection and named source/Contract paths; no execution','runtime_claim':'NONE','independent_review':'AWAITING_INDEPENDENT_REVIEW','review_conclusion':''})
end_drift=[p for p,h in fingerprints.items() if sha(ROOT/p)!=h]
assert not end_drift, 'concurrent input change: '+str(end_drift)
report={'classification':'DEVELOPER_STATIC_OBSERVATION_CANDIDATE','producer':'python3 scripts/stage9_static_candidate.py','producer_sha256':sha(Path(__file__)),'review_conclusion':None,'runtime_pass_claims':0,'fixed_source_reference':fixed_path,'fixed_manifest_sha256':sha(ROOT/fixed_path),'bindings':bind,'input_drift_start_end':end_drift,'source_graph':{'compiled_sources':source,'copied_resource_files':resources,'build_phases':phases,'imports':imports,'package_pin':json.loads(read(pin)),'package_manifest_and_sources_sha':{str(p):sha(p) for p in package_sources},'excluded_noncompiled_swift':sorted(set(str(p.relative_to(ROOT)) for p in (ROOT/'IncomeClock').rglob('*.swift'))-set(source))},'copy_index':copy_index,'copy_phrase_hits':copy_hits,'profile_dependency_phrase_hits':profile_hits,'theme_forbidden_api_hits':theme_hits,'checklist_structure':structure,'validator_closure_rebound':closure,'observations':result,'limitations':['No build/app/test/reader/network/signed entitlement or actual hardware operation.','No source snapshot directory created. Source proofs bind existing023 only where exact SHA equal; documents bind current listed bytes.','Old static observations/reviews/ledger preserved. No independent PASS/finding closure/state changes.','Input content and hashes are fixed by this small candidate; rerun to a new observation if source/governance changes.'],'artifact_disposition':{'run_root_mutations':0,'build_count':0,'app_launches':0,'deletions':0,'final_acceptance':'PENDING','deployment':'NOT_AUTHORIZED'}}
write(ROOT/'STAGE9_CLOSEOUT_STATIC_CANDIDATE.json',report)
p=ROOT/'STAGE9_CLOSEOUT_STATIC_CANDIDATE.tsv'; assert not p.exists()
with p.open('w') as f:
    w=csv.DictWriter(f,fieldnames=list(result[0]),delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(result)
print(json.dumps({'rows':len(result),'copy_phrase_hits':copy_hits,'profile_hits':profile_hits,'theme_hits':theme_hits,'structure':structure,'bytes':sum((ROOT/p).stat().st_size for p in ['STAGE9_CLOSEOUT_STATIC_CANDIDATE.json','STAGE9_CLOSEOUT_STATIC_CANDIDATE.tsv'])},ensure_ascii=False))
