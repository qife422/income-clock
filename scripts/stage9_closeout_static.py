#!/usr/bin/env python3
"""Small deterministic source/config observations, separate from runtime proof."""
from pathlib import Path
import csv,hashlib,json,plistlib,re
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def text(p):return (ROOT/p).read_text()
results=[]
def check(ids,files,predicate,condition,scope='SOURCE_ONLY',details=''):
 for rid in ids.split():
  results.append(dict(atomic_requirement_id=rid,observation=predicate,actual_result='PASS' if condition else 'FAIL',scope=scope,source_bindings='; '.join(f'{p}#{sha(ROOT/p)}' for p in files),details=details,method='python3 scripts/stage9_closeout_static.py',runtime_claim='NONE',independent_review='PENDING'))
prod=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'IncomeClock').rglob('*.swift'))
ui=[p for p in prod if '/Presentation/' in p]
business=[p for p in prod if '/Domain/' in p or p in ['IncomeClock/Application/BusinessStore.swift','IncomeClock/Application/BusinessStoreModels.swift']]
theme=[p for p in prod if '/Theme/' in p or '/Theme' in p]
entfile='IncomeClock/Resources/IncomeClock.entitlements';ent=plistlib.loads((ROOT/entfile).read_bytes())
proj='IncomeClock.xcodeproj/project.pbxproj';pbx=text(proj)
check('T-045.deployment_target',[proj],'Every declared MACOSX_DEPLOYMENT_TARGET equals 13.0',set(re.findall(r'MACOSX_DEPLOYMENT_TARGET = ([^;]+);',pbx))=={'13.0'})
imports={m for p in prod for m in re.findall(r'^import\s+(\w+)',text(p),re.M)}
packages=set(re.findall(r'repositoryURL = "([^"]+)";',pbx))
web_files=[str(p.relative_to(ROOT)) for p in (ROOT/'IncomeClock').rglob('*') if p.is_file() and p.suffix.lower() in {'.html','.htm','.js','.mjs','.css','.wasm'}]
check('P21-002.a',[proj]+prod,'Compiled native app dependency graph has only ZIPFoundation external package and no web framework/runtime assets',
      packages=={'https://github.com/weichsel/ZIPFoundation.git'} and not imports&{'WebKit','JavaScriptCore','WKWebView','Electron','Tauri'} and not web_files,
      scope='DIRECT_BUILD_DEPENDENCY',details='Closed production Swift import inventory: '+','.join(sorted(imports))+'; inspected complete application resource suffix inventory. This architectural claim is separate from runtime offline evidence.')
check('P21-004.a',[proj]+prod,'Native application has no WidgetKit import/target and amount implementation is AppKit/SwiftUI',
      'WidgetKit' not in imports and 'com.apple.product-type.app-extension' not in pbx and 'struct IncomePanelView: View' in text('IncomeClock/Presentation/Panel/EmptyPanelView.swift'),
      scope='DIRECT_BUILD_DEPENDENCY',details='Actual amount runtime is covered separately by production TimelineView/native amount tests; this observation closes only non-use of WidgetKit.')
menufile='IncomeClock/Presentation/MenuBar/MenuBarContentView.swift'
menu=text(menufile)
check('UI18-035.no_animation_character',[menufile],'Complete MenuBarContentView contains only Text/Button/Toggle/Divider presentation, no character resource or animation producer',
      all(x not in menu for x in ['Image(', 'TimelineView', '.animation(', 'withAnimation', 'ThemeImportStandardPanelPreview', 'decorationResource', 'resourceURL'])
      and all(x in menu for x in ['private var summary:', 'Text(presentation.status)', 'Toggle("登录时启动"']),
      scope='DIRECT_MENU_PRESENTATION',details='Entire view and both local rendering helpers inspected; actions only dispatch to services/Store. System-native menu hover is not a product character/amount animation.')
check('T-046.a',[proj,entfile],'Source entitlement exact sandbox + user-selected read-only; Hardened Runtime configured; no network entitlement',ent=={'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True} and pbx.count('ENABLE_HARDENED_RUNTIME = YES;')==2,scope='PARTIAL_SOURCE_CONFIG_ONLY',details='Unsigned build has no codesigned entitlement claim; Release bundle/static effective settings must be separately inspected.')
check('T-047.a',[entfile],'Only user-selected read-only file entitlement',ent.get('com.apple.security.files.user-selected.read-only') is True and not any('read-write' in k or 'network' in k for k in ent),scope='PARTIAL_ENTITLEMENT_ONLY',details='Repository runtime root access requires code-path review; this does not inspect all actual file I/O.')
forbidden=['URLSession','WKWebView','JavaScriptCore','NSAppleScript','Process(','dlopen(','system(','popen(']
hits=[f'{p}:{word}' for p in theme for word in forbidden if word in text(p)]
check('P21-102.a T-050.a',theme,'Theme source has no network/web/eval/process-loading invocation in explicit forbidden API set',not hits,scope='PARTIAL_CLOSED_SOURCE_SCAN',details='; '.join(hits) or 'No invocation in audited Theme source; security corpus supplies data-validation side. Does not infer all runtime behavior merely from keyword absence.')
focus=['PanelPresentationProfile','contentSafeArea','primaryDragRegion','standard.panel.320x190','layoutProfile','panelProfile']
hits=[f'{p}:{word}' for p in business for word in focus if word in text(p)]
check('P21-109.a UI18-004.a',business+['IncomeClock/Presentation/Panel/PanelPresentationProfile.swift'],'Business/domain records and state machine do not reference presentation Profile constants or registry',not hits,scope='DIRECT_STATIC_BOUNDARY',details='; '.join(hits) or 'All production Domain + BusinessStore + BusinessStoreModels files scanned; profile source owns 320x190/safe-area constants.')
profile='IncomeClock/Presentation/Panel/PanelPresentationProfile.swift'
check('UI18-005.a',[profile,'IncomeClock/App/AppEnvironment.swift'],'Production default Profile registry contains standard only', 'init(profiles: [PanelPresentationProfile] = [.standard])' in text(profile) and 'static let standardProfileID = "standard.panel.320x190.v1"' in text(profile),scope='PARTIAL_DEFAULT_PROFILE',details='No claim that future registered profile IDs are supported at runtime; manifest negotiation checked separately.')
clockhits=[f'{p}:{word}' for p in ui for word in ['Calendar.current','TimeZone.current'] if word in text(p)]
check('UI18-022.a',ui,'Presentation files do not directly read Calendar.current or TimeZone.current',not clockhits,scope='PARTIAL_NO_UI_CLOCK_READ',details='Settings command tuple/publication must additionally be proven by T013/runtime Presentation observation.')
copyhits=[f'{p}:{word}' for p in ui for word in ['工资速度','收入速率','每小时收入','每秒收入','¥/h','¥/s'] if word in text(p)]
check('P21-025.a P22-037.a',ui,'No forbidden wage-rate copy in complete Presentation source strings',not copyhits,scope='PARTIAL_COPY_AUDIT',details='Explicit forbidden phrase scan; independently inspect user-visible strings for synonyms, dynamic copy or localization omission.')
login='IncomeClock/Infrastructure/LoginItem/SMAppServiceLoginItemService.swift';ls=text(login)
launch=[p for p in prod if any(w in text(p) for w in ['LaunchAgents/','LaunchDaemons/','launchctl'])]
check('T-049.a',[login]+prod,'Main-app SMAppService used; no launch-agent/daemon installation path',all(x in ls for x in ['SMAppService.mainApp.status','SMAppService.mainApp.register()','SMAppService.mainApp.unregister()']) and not launch,scope='DIRECT_STATIC_ADAPTER',details='Real register/unregister/login runtime remains X009/T027 external gate.')
notif='IncomeClock/Infrastructure/Notifications/UNUserNotificationCenterService.swift';ns=text(notif)
prohibited=['AXIsProcessTrustedWithOptions','CGRequestScreenCaptureAccess','requestWhenInUseAuthorization','requestAlwaysAuthorization','NSAppleScript']
permissionhits=[f'{p}:{w}' for p in prod for w in prohibited if w in text(p)]
check('T-048.a',[notif]+prod,'Notification permission via UNUserNotificationCenter; no forbidden permission request in source', 'center.requestAuthorization(options: [.alert, .sound])' in ns and not permissionhits,scope='PARTIAL_CLOSED_SOURCE_SCAN',details='XCTest accessibility entitlement is test infrastructure only; actual user/system request gate remains external.')
ledger_root=ROOT.parent/'可视收入打卡机_review_inputs/stage9-s9r001-evidence-consistency-repair-2026-08-24-001/Evidence/Ledger'
def rows(path):return list(csv.DictReader(path.open(),delimiter='\t'))
contract_rows=rows(ledger_root/'STAGE9_CONTRACT_REQUIREMENT_COVERAGE_LEDGER.tsv')
gate_rows=rows(ledger_root/'STAGE9_DERIVED_GATE_LEDGER.tsv')
contract_ids=[r['sub_requirement_id'] for r in contract_rows]
gate_ids=[r['gate_id'] for r in gate_rows]
actual_rows=rows(ROOT/'STAGE9_CLOSEOUT_DISPOSITION.tsv')
actual_ids=[r['atomic_requirement_id'] for r in actual_rows]
complete=(len(contract_ids)==len(set(contract_ids))==370 and len(gate_ids)==len(set(gate_ids))==12
 and not set(contract_ids)&set(gate_ids) and len(actual_ids)==len(set(actual_ids))==382
 and set(actual_ids)==set(contract_ids)|set(gate_ids))
check('T-028.a',['STAGE9_CLOSEOUT_DISPOSITION.tsv'],'Complete 370 Contract +12 derived gate checklist, disjoint unique IDs',complete,scope='DIRECT_GOVERNANCE_STRUCTURE',details='Recomputes exact equality with both fixed ledgers, uniqueness and disjointness; coverage only, never checked-off conformance.')
readme=ROOT/'README.md'
if readme.exists():
 content=readme.read_text();check('P23-08.a',['README.md'],'Project delivery notes disclose local data/device clock/notification uncertainty',all(w in content for w in ['本地','时钟','通知']) and any(w in content for w in ['不保证','不能保证','不承诺']),scope='DIRECT_DOCUMENT_CONTENT')
# Explicit supplemental source and historical-record scopes; never physical PASS.
record_source='IncomeClock/Infrastructure/Persistence/PersistenceRecords.swift'
record_body=text(record_source).split('struct TodayRecord:')[1].split('func replacingRevision')[0]
clockout_body=record_body.split('if let clockOutAtMs {')[1].split('switch (notificationScheduledDateKey')[0]
check('T-005.a',[record_source],'TodayRecord clock-out validation has only >=clockIn relation and no day-count ceiling',
      'guard clockOutAtMs >= clockInAtMs else' in clockout_body and clockout_body.count('guard ')==1 and '<=' not in clockout_body and 'day' not in clockout_body.lower(),
      scope='PARTIAL_SOURCE_NO_DAY_CEILING',details='Combined with named next/multi-day acceptance, early-clockout rejection and capped-calculator tests; this source fragment alone does not prove all T005.')
fontsource='IncomeClock/Presentation/Panel/EmptyPanelView.swift'
check('P21-099.monospaced_digits',[fontsource],'Amount native font factory starts with NSFont.monospacedDigitSystemFont; rounded variant derives its descriptor',
      'NSFont.monospacedDigitSystemFont(ofSize: size, weight: nativeWeight)' in text(fontsource) and 'font.fontDescriptor.withDesign(.rounded)' in text(fontsource),
      scope='PARTIAL_FONT_FACTORY',details='Native tests consume this font; successor named ten-digit equal-advance test is execution-unbound until its own run. This observation itself remains only the factory declaration.')
review='STAGE4_REVIEW.md'; active='DEVELOPMENT_STATE.md'
check('T-058.automated_single_display',[review,'STAGE4_REPORT.md','SPEC_INDEX.md'],
      'Historical Stage4 review records 001/002/004/005 CLOSED and preserves 003 DEFERRED; automated/single-display scope only',
      all(re.search(r'\| '+finding+r' \|[^\n]+CLOSED',text(review)) for finding in ['S4R-001','S4R-002','S4R-004','S4R-005']) and 'DEFERRED — RELEASE HARD GATE' in text(review),
      scope='DIRECT_HISTORICAL_RECORD',details='Asserts existence/content of historical records, not current code conformance or reuse of stale binaries. Current harness tests separately mapped T023.')
active_scope=text(active).split('## 42. Stage 9 批量软件收尾授权')[1]
check('T-029.a',[review,active,'TECH_SPEC.md'],
      'S4R003 remains deferred release hard gate; current batch explicitly preserves system boundaries',
      'DEFERRED — RELEASE HARD GATE' in text(review) and '不等于 closed、passed 或 verified' in text(review) and 'S4R-003、真实系统门禁、最终人类接受与部署授权保持独立' in active_scope,
      scope='DIRECT_GOVERNANCE_GATE',details='Only verifies maintained gate policy/status; no simulated/system test can close physical S4R003. Historical approval/authorization not extended.')
with (ROOT/'STAGE9_CLOSEOUT_STATIC_OBSERVATIONS.tsv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(results[0]),delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(results)
print(json.dumps({'observations':len(results),'failures':[r['atomic_requirement_id'] for r in results if r['actual_result']=='FAIL'],'runtime_pass_claims':0},ensure_ascii=False,indent=2))
