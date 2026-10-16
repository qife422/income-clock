#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read exported closure results; bind exact source and named predicates only.
Does not build, open result bundles, modify ledgers, or adjudicate Review.
"""
from pathlib import Path
import csv, hashlib, json, re, collections
R=Path(__file__).resolve().parents[1]
def sha(data): return hashlib.sha256(data if isinstance(data,bytes) else data.encode()).hexdigest()
def read(name):
    with (R/name).open() as f:return list(csv.DictReader(f,delimiter='\t'))
def write(name,rows):
    assert rows
    with (R/name).open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]),delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(rows)
def doc(name):return json.loads((R/name).read_text())
def body(text,name):
    lines=text.splitlines(keepends=True);starts=[i for i,l in enumerate(lines) if re.search(r'func '+re.escape(name)+r'\(',l)]
    if len(starts)!=1:return None
    i=starts[0];j=i+1
    while j<len(lines) and not re.match(r'    }\s*$',lines[j]):j+=1
    value=''.join(lines[i:j+1])
    return {'method_range':f'{i+1}-{j+1}','method_sha256':sha(value),'assertions':' | '.join(f'{i+k+1}:{line.strip()}' for k,line in enumerate(lines[i:j+1]) if 'XCTAssert' in line or 'XCTFail' in line)}
# Reconstruct one old file in memory, not by attributing today's bytes to old run.
# Full-file SHA must match the historical run manifest before any method is used.
reconstructions=[]
def source(rel,digest):
    for p in [R/rel,*sorted((R/'stage9_closeout_evidence').glob('code-candidate-*/'+rel)), *sorted((R/'stage9_closeout_evidence/source-fragments').glob('*/'+rel))]:
        if p.is_file() and sha(p.read_bytes())==digest:return p.read_text(),str(p.relative_to(R)),'EXACT_FILE_SHA256'
    if rel=='IncomeClockApplicationTests/Stage8ThemeImportTests.swift':
        current=(R/rel).read_text();start=current.index('        // P22-064: vary an actual standard-profile')
        end=current.index('        clock.set(ApplicationTestSupport.timestamp(hour: 12))',start)
        restored=current[:start]+current[end:]
        if sha(restored)==digest:
            recipe={'source_file':rel,'current_sha256':sha(current),'remove_exact_segment_sha256':sha(current[start:end]),'start_anchor':current[start:].splitlines()[0],'end_anchor':current[end:].splitlines()[0],'reconstructed_full_file_sha256':digest,'method':'Remove only later-added Profile comparison block in memory, then exact complete-file SHA equality; no Swift file written.'}
            if recipe not in reconstructions:reconstructions.append(recipe)
            return restored,rel+'#verified-in-memory-prior-profile-reconstruction','EXACT_RECONSTRUCTED_FILE_SHA256'
    return None,'','UNAVAILABLE_NO_METHOD_BINDING'
# Each run has its own source/build/command provenance. No renamed old run.
specs=[
 ('CLOSURE_DIRECTED','CLOSURE_NATIVE_REPAIR','CLOSURE_BUILD'),
 ('CLOSURE_EVENT_QUEUE','CLOSURE_EVENT_QUEUE','CLOSURE_EVENT_QUEUE_BUILD'),
 ('CLOSURE_UI_ACCESS','CLOSURE_ACCESSIBILITY','CLOSURE_ACCESSIBILITY_UI_BUILD'),
 ('CLOSURE_REFRESH','CLOSURE_REFRESH','CLOSURE_REFRESH_BUILD'),
 ('CLOSURE_DST_UI','CLOSURE_DST_UI','CLOSURE_DST_UI_BUILD'),
 ('CLOSURE_RECOVERY','CLOSURE_RECOVERY','CLOSURE_RECOVERY_BUILD'),
 ('CLOSURE_FINAL_UI','CLOSURE_RECOVERY','CLOSURE_FINAL_UI_BUILD')]
catalog=[];methods=[];cache={}
for tag,src,build in specs:
    names={k:'STAGE9_'+v+'.json' for k,v in {'summary':tag+'_SUMMARY','tests':tag+'_TESTS','source':src+'_SOURCE','command':tag+'_COMMAND','execution':tag+'_EXECUTION','build_command':build+'_COMMAND','build_execution':build+'_EXECUTION'}.items()}
    available={k:(R/v).exists() for k,v in names.items()}
    if not all(available.values()):
        catalog.append({'run':tag,'status':'PENDING_EXPORT_OR_PROVENANCE','missing':[names[k] for k,v in available.items() if not v],'paths':names});continue
    d={k:doc(v) for k,v in names.items()}
    assert d['execution']['command']==d['command']
    assert d['build_execution']['command']==d['build_command'] and d['build_execution']['exit']==0
    assert 'test-without-building' in d['command'] or 'test-without-build' in d['command']
    leaves=[]
    def walk(n):
        if n.get('nodeType')=='Test Case':leaves.append(n)
        for c in n.get('children',[]):walk(c)
    for n in d['tests']['testNodes']:walk(n)
    counts=collections.Counter(n['result'] for n in leaves)
    assert len(leaves)==sum(d['summary'][x] for x in ['passedTests','failedTests','skippedTests'])
    assert len({x['nodeIdentifierURL'] for x in leaves})==len(leaves)
    for result,key in [('Passed','passedTests'),('Failed','failedTests'),('Skipped','skippedTests')]:assert counts[result]==d['summary'][key]
    assert (d['execution']['exit']==0)==(counts['Failed']==0)
    changed=[];files={}
    for rel,digest in d['source'].items():
        if not (R/rel).is_file() or sha((R/rel).read_bytes())!=digest:changed.append(rel)
        if rel.endswith('.swift') and 'Tests/' in rel:
            key=(rel,digest)
            if key not in cache:cache[key]=source(rel,digest)
            files[rel]=cache[key]
    catalog.append({'run':tag,'status':'EXPORTED_RESULTS_VALIDATED','paths':names,'sha256':{k:sha((R/v).read_bytes()) for k,v in names.items()},'counts':dict(counts),'start_time':d['summary']['startTime'],'environment':d['summary'].get('devicesAndConfigurations',d['tests'].get('devices',[])),'xcresult':d['command'][d['command'].index('-resultBundlePath')+1],'source_files':len(d['source']),'current_source_differences':changed,'limitation':'Producer source/method predicates; no independent sufficiency/compatibility verdict.'})
    for node in leaves:
        target,cls,name=node['nodeIdentifierURL'].rsplit('/',3)[-3:]
        matches=[]
        for rel,(text,path,kind) in files.items():
            if not text or Path(rel).parts[0]!=target:continue
            found=body(text,name)
            if found:
                prefix=text.split('func '+name+'(',1)[0]
                classes=re.findall(r'\bclass\s+(\w+)\s*:\s*XCTestCase',prefix)
                if classes and classes[-1]==cls:matches.append((rel,text,path,kind,found))
        row={'run':tag,'method':name,'raw_result':node['result'],'raw_node':node['nodeIdentifierURL'],'raw_tests':names['tests'],'raw_tests_sha256':sha((R/names['tests']).read_bytes()),'source_binding':'UNAVAILABLE_NO_METHOD_BINDING','source_file':'','source_locator':'','run_source_file_sha256':'','method_range':'','method_sha256':'','current_method_equal':False,'assertions':'','current_production_changed_files':'; '.join(p for p in changed if p.startswith('IncomeClock/')),'limitation':'Actual raw result only until exact source binding; no whole-row PASS.'}
        if len(matches)==1:
            rel,text,path,kind,found=matches[0];cur=body((R/rel).read_text(),name)
            row.update(source_binding=kind,source_file=rel,source_locator=path,run_source_file_sha256=sha(text),**found,current_method_equal=bool(cur and cur['method_sha256']==found['method_sha256']),limitation='Exact exported raw node and full file SHA; unchanged method does not adjudicate all helper/production dependencies or atomic sufficiency.')
        methods.append(row)
for run in catalog:
    wrapper=R/('STAGE9_KEYBOARD_NAVIGATION_'+run['run']+'_EXECUTION.json')
    if wrapper.exists():
        value=json.loads(wrapper.read_text())
        run['keyboard_navigation_wrapper']={'path':wrapper.name,'sha256':sha(wrapper.read_bytes()),'enabled_appkit':value.get('enabled_appkit'),'restore_verified':value.get('restore_verified'),'original_present':value.get('original_present'),'restored_present':value.get('restored_present'),'limit':'Actual wrapper readback only; no other OS accessibility preference or real permission claim.'}
# Exact assertion mappings are shared with normal catalog; no suite -> PASS rule.
links=read('STAGE9_CLOSEOUT_ASSERTION_CANDIDATES.tsv');bindings=[]
for m in methods:
    for link in links:
        if link['method']!=m['method']:continue
        if m['source_file'] and link['test_file']!=m['source_file']:continue
        bindings.append({'atomic_requirement_id':link['atomic_requirement_id'],'coverage_scope':link['coverage_scope'],'predicate':link['assertion_predicate'],**m,'producer_predicate_status':'RAW_PASSED_EXACT_METHOD_PENDING_REVIEW' if m['raw_result']=='Passed' and m['current_method_equal'] else 'RAW_RESULT_OR_SOURCE_GAP_PENDING_REVIEW'})
for binding in bindings:
    binding.pop('assertions',None)
    binding['assertion_anchors_reference']='STAGE9_CLOSURE_RUN_METHODS.tsv#'+binding['run']+'/'+binding['method']
assert methods and bindings
write('STAGE9_CLOSURE_RUN_METHODS.tsv',methods)
write('STAGE9_CLOSURE_PREDICATE_BINDINGS.tsv',bindings)
(R/'STAGE9_CLOSURE_RUN_CATALOG.json').write_text(json.dumps({'classification':'PRODUCER_SUPPLEMENTAL_CATALOG_NOT_REVIEW','runs':catalog,'source_reconstructions':reconstructions,'historical_catalog_preserved':'STAGE9_CLOSEOUT_RUN_CATALOG.tsv','limits':['No result assigned from method count or green build.','Original failures, raw identifiers and run names retained.','Unexported runs stay pending; no result bundle is parsed by this script.','Source reconstruction is accepted only at complete-file digest equality.']},ensure_ascii=False,indent=2)+'\n')
# Make all other closure executions visible without treating absent exports as PASS.
inventory=[]
for p in sorted(R.glob('STAGE9_CLOSURE*_EXECUTION.json')):
    e=json.loads(p.read_text());c=e.get('command',[])
    inventory.append({'execution':p.name,'sha256':sha(p.read_bytes()),'exit':e.get('exit'),'xcresult':c[c.index('-resultBundlePath')+1] if '-resultBundlePath' in c else '', 'classification':'BUILD_ONLY' if 'BUILD_EXECUTION' in p.name else 'RAW_EXPORTED_IN_SUPPLEMENT' if any(x['paths']['execution']==p.name and x['status']=='EXPORTED_RESULTS_VALIDATED' for x in catalog) else 'PENDING_OR_DIAGNOSTIC_WITHOUT_EXPORTED_METHODS'})
(R/'STAGE9_CLOSURE_EXECUTION_INVENTORY.json').write_text(json.dumps(inventory,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'runs':[(c['run'],c['status'],c.get('counts')) for c in catalog],'method_rows':len(methods),'exact_source_rows':sum(m['source_binding']!='UNAVAILABLE_NO_METHOD_BINDING' for m in methods),'raw_predicate_bindings':len(bindings),'source_reconstructions':len(reconstructions)},ensure_ascii=False))
# Operational remainder is not a new 174-test demand. Separate observed runtime
# deltas from pending source/atomic assembly, visual review and actual new input.
latest={}
for m in methods:latest[m['method']]=m
byid=collections.defaultdict(list)
for b in bindings:
    if latest.get(b['method'],{}).get('run')==b['run']:byid[b['atomic_requirement_id']].append(b)
observed_updates={
 'P21-105.a':('DIAGNOSTIC_FIXTURE_OBSERVED','Four named required-capability/version/minimum-app/Profile diagnostics actually Passed in CLOSURE_DIRECTED; no repeat of those fixtures. Assemble visible reason/source compatibility with the atomic clause.'),
 'P22-061.a':('DIAGNOSTIC_FIXTURE_OBSERVED','Unknown capability name/version and required Profile ID rejection have actual diagnostic, zero-write, Theme directory and business preservation assertions. Only bounded applicability/atomic review remains for this repair.'),
 'P21-094.a':('IMMEDIATE_DEFAULT_GAP_OBSERVED','Immediate post-restoreDefault disk/repository/effective selection equality actually Passed. Assemble prior startup/upgrade/fallback bindings; do not rerun solely for the formerly missing immediate assertion.'),
 'P22-064.a':('CHANGED_PROFILE_GAP_OBSERVED','Refresh changed standard Profile is consumed by actual mounted production frame and compared to unchanged-profile control through full business/notification/record/amount trajectory. No additional Profile mutation experiment is presently identified; exact dependency and atomic review remain.'),
 'P21-084.a':('ACTIVE_ANIMATION_ACTION_GAP_OBSERVED','Refresh observes activeAnimationCount>0 immediately before mounted primary action, then confirmation and persisted settlement. Active-animation action timing no longer needs another experiment; broad pointer hit-testing is not claimed.'),
 'P22-063.a':('MASK_HIT_REGION_COMPARISON_STILL_MISSING','Keep actual mask negotiation/install/restore/rejection PASS. Still compare optional-mask+standard-fallback versus no-mask using same business input and real primary/settings/hide/drag hit regions; the changed-Profile experiment is different.'),
 'UI18-041.business_retry':('BUSINESS_RETRY_CORE_OBSERVED','Refresh schedule-entry matrix and invalid/valid retry verify no failed business ViewState/record publication. Actual startup Settings entry/correction remains separately failed under UI18-041.real_settings_flow.'),
 'UI18-041.real_settings_flow':('LATEST_NATIVE_STARTUP_FAILED','CLOSURE_DST_UI startup method Failed at ambiguous Open Settings selector. Source/selector repair requires its new actual run; no earlier failed-method prefix is counted as PASS.'),
 'UI18-037.a':('FOLD_PASS_GAP_METHOD_FAILED','Actual fold both fields Passed with old full-file SHA preserved; gap method Failed later in page-label lookup, so retain exact failed node and do not turn its preceding steps into a completed predicate. New repaired gap selector run remains needed.'),
 'P21-019.a':('FOLD_PASS_GAP_METHOD_FAILED','Fold start/end draft retention/focus/unique correction has exact actual PASS; latest gap method remains Failed. Assemble resolver/field/malformed-range rules separately; no OS success-announcement proof inferred.'),
 'P22-014.a':('FOLD_PASS_GAP_METHOD_FAILED','Native fold both boundaries actually Passed; native gap method not fully Passed. Keep business resolver/preflight evidence and await repaired gap test; no whole-time-rule PASS inferred.'),
 'P22-015.a':('LATEST_NATIVE_STARTUP_FAILED','Business retry core Passed in Refresh; actual DST startup Settings recovery is Failed and needs the repaired selector/production run. Do not substitute damaged-Settings recovery.'),
 'UI18-018.a':('LATEST_NATIVE_STARTUP_FAILED','Actual startup gap method Failed, so no complete real no-business-surface->Settings recovery PASS. Complete new targeted run; hosted/business nil-state evidence remains separate.'),
 'UI18-019.a':('LATEST_DAMAGED_RECOVERY_FAILED','CLOSURE_DST_UI damaged Settings reset/replacement method Failed. Complete authorized production repair and actual rerun before claiming error visibility and explicit replacement cleared state.'),
 'UI18-022.a':('LATEST_DAMAGED_RECOVERY_FAILED','Refresh preconstructed target/retry core Passed; actual damaged Settings replacement flow Failed. Bind new repaired actual UI result with existing command-context/preflight/loading/failure evidence.'),
 'UI18-036.minimum_size':('NATIVE_MINIMUM_RUN_PENDING','Minimum-size test is now source only: await actual grow/shrink clamp at680x500 content with separately measured titlebar; seven-page focus/automatic-scroll and named conditional error visibility. Hosted fittingSize alone remains insufficient.'),
 'P23-04.settings':('NATIVE_MINIMUM_RUN_PENDING','Run pending actual native minimum-size and keyboard test; retained single initial-page bitmap does not prove seven-page Settings usability or conditional errors.'),
 'UI18-036.keyboard_all_pages':('HOSTED_KEYBOARD_PASS_NATIVE_COMPLETION_PENDING','Refresh General/Work/Panel/Data/shortcut/about native responder-chain method Passed; EventQueue installed/recovery keyboard method Passed but its old helper/file source remains unavailable. Need bound latest installed/recovery result plus actual seven-page minimum-size run; do not repeat General solely for old failures.'),
}
# Success/failure state follows exact latest exported node; never hard-code a
# pending/failed phrase after a newer completed run has become available.
damaged_latest=latest.get('testDamagedSettingsResetCancellationAndExplicitReplacementKeepCorrectSurfaces',{})
if damaged_latest.get('raw_result')=='Passed' and damaged_latest.get('current_method_equal'):
    observed_updates['UI18-019.a']=('DAMAGED_NATIVE_RECOVERY_OBSERVED','FINAL_UI actual damaged Settings reset cancellation and explicit replacement Passed with exact preserved source. Its specific native recovery gap no longer needs another run; valid-Today and full matrix remain separate exact bindings.')
    observed_updates['UI18-022.a']=('DAMAGED_NATIVE_RECOVERY_OBSERVED','FINAL_UI actual reset/cancel/explicit replacement Passed; combine with Refresh command-context/preconstructed target and prior held-save matrices. No same-method repeat requested solely for older DST_UI failure.')
for rid in ['UI18-041.real_settings_flow','P22-015.a','UI18-018.a']:
    if latest.get('testStartupDSTGapOpensSettingsAndFailedRetryPreservesRecordsUntilCorrection',{}).get('run')=='CLOSURE_FINAL_UI':
        observed_updates[rid]=('LATEST_NATIVE_STARTUP_FAILED','FINAL_UI startup method Failed with application accessibility-not-loaded. Keep preceding DST_UI selector failure historical. Actual completed startup correction requires the repaired launch/session run; no partial method PASS.')
for rid in ['P21-019.a','P22-014.a','UI18-037.a']:
    if latest.get('testSettingsInlineValidationRetainsInputsAndSevenPagesAreReachable',{}).get('run')=='CLOSURE_FINAL_UI':
        observed_updates[rid]=('FOLD_PASS_GAP_METHOD_FAILED','Fold both fields remains exact Passed in DST_UI. FINAL_UI gap/placement/pages method Failed at Shortcut page assertion; do not infer whole-method PASS from previous steps. Existing resolver/preflight scope stays separate.')
for rid in ['UI18-036.minimum_size','P23-04.settings']:
    if latest.get('testNativeMinimumSettingsSevenPagesKeyboardAndCommittedPreferences',{}).get('raw_result')=='Failed':
        observed_updates[rid]=('MINIMUM_ENTRY_FAILED_BEFORE_MEASUREMENT','FINAL_UI minimum method Failed at early Cmd-comma Settings entry before resize/focus measurement. Existing native gear entry is a bounded test repair; actual minimum geometry and seven-page selected-control result remains unobserved.')
remainder=[]
for row in read('STAGE9_CLOSEOUT_REMAINING_PREDICATES.tsv'):
    rid=row['atomic_requirement_id'];group=row['minimal_action_group'];state,predicate=observed_updates.get(rid,('EXISTING_ATOMIC_ASSEMBLY_OR_NAMED_MISSING_OBSERVATION',row['minimum_remaining_predicate']))
    bs=byid[rid]
    # m values above are booleans before TSV serialization.
    passed=[b for b in bs if b['raw_result']=='Passed' and b['current_method_equal'] is True]
    if row['closure_route'].startswith('REVIEWED_'):kind='REVIEW_EXISTING_STATIC_OR_HISTORICAL_CLAUSE'
    elif group.startswith('E-') or group.startswith('S-'):kind='ASSEMBLE_EXISTING_EXACT_EVIDENCE_FIRST'
    elif group.startswith('G-'):kind='EXTERNAL_GATE_EXCLUDED_FROM_SOFTWARE'
    elif group.startswith('V-'):kind='NAMED_VISUAL_OBSERVATION_OR_EXISTING_IMAGE_REVIEW'
    elif group.startswith('A-'):kind='LOCAL_RELEASE_ARTIFACT_OBSERVATION'
    else:kind='NAMED_NATIVE_OR_CONTROLLED_OBSERVATION'
    if state in {'DIAGNOSTIC_FIXTURE_OBSERVED','IMMEDIATE_DEFAULT_GAP_OBSERVED','CHANGED_PROFILE_GAP_OBSERVED','ACTIVE_ANIMATION_ACTION_GAP_OBSERVED','BUSINESS_RETRY_CORE_OBSERVED','DAMAGED_NATIVE_RECOVERY_OBSERVED'}:kind='NEW_RUNTIME_PREDICATE_ASSEMBLY_NO_REPEAT_REQUEST'
    remainder.append({'atomic_requirement_id':rid,'atomic_requirement':row['atomic_requirement'],'work_kind':kind,'action_group':group,'current_predicate_state':state,'exact_new_passed_methods':'; '.join(sorted({b['run']+'/'+b['method'] for b in passed})),'other_latest_raw_results':'; '.join(sorted({b['run']+'/'+b['method']+':'+b['raw_result']+'/'+b['source_binding'] for b in bs if b not in passed})),'minimum_remaining_predicate':predicate,'evidence_mapping':'STAGE9_CLOSURE_PREDICATE_BINDINGS.tsv#'+rid if bs else row['row_applicability_reference'],'limit':'Producer work planning; not full atomic acceptance, Review conclusion or Finding closure. Historical canonical status preserved.'})
write('STAGE9_CLOSURE_REMAINING_SOFTWARE.tsv',remainder)
# Detailed groups isolate actual unobserved actions, rather than calling all
# not-yet-adjudicated rows missing executions.
missing_groups=[
 ('optional mask','P22-063.a','同一输入下 optional mask+标准fallback 的实际业务与主要按钮/设置/隐藏/拖拽命中区域对照；验证/安装/恢复mask已实跑，不重复其语料。'),
 ('DST native recovery','P21-019.a P22-014.a P22-015.a UI18-037.a UI18-041.real_settings_flow UI18-018.a','fold 双边界已有精确PASS；FINAL_UI gap在快捷键页断言失败、startup为accessibility-not-loaded，等待修正后的完整实际结果。failed方法前半步骤不自动PASS；成功announcement未独立监听。'),
 ('damaged Settings','UI18-019.a UI18-022.a','FINAL_UI damaged Settings 已实际PASS，Recovery两方法已PASS；不再要求这两个特定修复重复执行。只把新node与已有typed-load/双损坏/plan-before-commit完整矩阵汇编，不视为全部recovery验收。'),
 ('minimum Settings / keyboard','UI18-036.minimum_size P23-04.settings UI18-036.keyboard_all_pages P21-080.keyboard P21-098.keyboard_focus UI18-003.focus_order UI18-050.focus_escape UI18-050.disabled_reason','真实窗口680×500内容区与标题栏分列，七页和条件错误核心控件可见/自动滚动；A/B及条件import/recovery焦点/Escape/disabled原因。General/Work/Panel的Refresh原生responder-chain PASS不再列为失败；旧installed/recovery PASS仍需完整旧source/helper绑定或新结果。'),
 ('shared app business flow','T-024.shared_state T-024.other_flows P21-021.a P21-046.a P21-058.a P22-006.a UI18-010.live_estimate','实际Settings→MenuBar clock-in→Panel确认实时估算/取消/提交→quit/relaunch共享同一Today的完整方法；已有close-Settings earning raw PASS保留，不代表完整共享流程。'),
 ('menu and agent UI','P21-001.menu_bar_runtime P21-003.a P21-073.open_settings P21-073.quit P21-074.a UI18-035.order_and_summary','原生菜单真实入口/退出、七状态summary顺序/分隔/快捷键/checked值与enabled动作；默认无Dock图标的运行观测。复用hosted七状态，不重做Store矩阵。'),
 ('single-display placement','P21-005.a P21-006.a P21-007.a P21-008.a P22-030.a','当前主屏四角drag/snap、重启位置、restore default和lock真实交互；最新含这些步骤的gap方法整体Failed，不能整方法记PASS。外接屏矩阵独立。'),
 ('inactive return','P21-041.panel_reshow P21-060.a P22-005.a UI18-028.background_recalibration','真实earning隐藏并inactive后返回：金额/倒计时按当下timestamp校准，无动画积压。仅hidden维护和最终重算不等于实际inactive-return。'),
 ('native Theme lifecycle','P21-086.browse P21-086.file_chooser P21-086.drag_drop P22-038.a P22-045.a P22-046.a P22-047.a P22-048.a UI18-042.management_ui UI18-044.a UI18-045.a P21-092.a','实际文件选择器/drag-drop、同版本reinstall、upgrade/拒绝、非当前delete、当前delete回退，以及earning下Panel/Menu/Settings可见选择与金额连续性。已有repository原子性/完整业务轨迹/当前默认一致性不重复。'),
 ('cross-surface visual gaps','P21-081.a P21-082.a P21-098.remaining_text_nontext_contrast P21-099.runtime_matrix P23-06.complete_light_dark P23-06.text_120 UI18-047.a UI18-051.a UI18-001.a UI18-049.decorative_tree','复用已reviewed Panel28状态及confirmation/settlement图，只检查具体尚缺的Settings/menu/error/focus与非主要控件对比度、Light/Dark/120%、1x尺度、未观察的B装饰状态AX树。完整矩阵不是重新导出28图。'),
 ('local Release','P21-001.macos13_declaration P23-04.macos13_declaration T-045.universal_app T-046.a T-047.a T-064.sandbox X-006.a','一个当前本地unsigned/ad-hoc范围Release产物：真实slice/load command/minOS/plist/nested executables/effective entitlements、隔离offline/no-network运行。Debug、源声明、build成功都不能代替。'),
 ('copy inventory','P21-025.a P22-037.a','补齐first-party动态插值/资源/新兼容诊断的可见文案清单；现quoted/CJK扫描仅partial；外部Theme文本分开处理。')]
lines=['# Closure 实际证据与软件剩余条件','', '这是 producer 原子谓词映射，不是独立 Review，也不是最终验收。原有 174 条是待汇编/裁决队列，不是 174 个待新增测试。所有历史失败和旧输入身份保留；新结果不改写旧 run。','', '## 新执行分别登记','']
for c in catalog:lines.append('- `'+c['run']+'`：'+str(c.get('counts',c['status']))+'；`'+c['paths']['summary']+'`。')
lines += ['', '## 已有新实跑，不再请求重复实验','', '- required capability/version/Profile/minimum-app 四诊断：Directed raw PASS；共享helper与旧完整测试文件已精确重建SHA。对应 P21-105.a / P22-061.a 的诊断缺口。', '- restoreDefault 返回后立即读取 disk/repository/effective selection：Directed raw PASS。只补 P21-094.a 原先缺的即时一致性，重启/升级旧证据仍需原子汇编。', '- 实际改变标准Profile、production frame确认消费并对照完整业务轨迹：Refresh raw PASS；P22-064.a 原动态对照缺口已获得候选证据。', '- activeAnimationCount>0 即刻触发mounted下班，再确认/持久化：Refresh raw PASS；P21-084.a 动画阻止操作的特定缺口已获得候选证据。', '- Refresh业务schedule-entry/retry/预构造target及General原生键盘方法各自PASS；不等于实际startup Settings入口、最小尺寸或全部UI验收。', '- DST_UI fold双字段实际PASS；旧源码完整SHA已保存。该run另外三个失败方法保持历史失败；后续FINAL_UI damaged方法的PASS单列，不从任何失败方法前缀推导PASS。', '', '## 仍需具体观测或新结果','']
for title,ids,description in missing_groups:
    lines+=['### '+title,'', '`'+ids+'`', '',description,'']
lines+=['## 只需先汇编旧证据，不等于新增执行','', '逐条清单在 `STAGE9_CLOSURE_REMAINING_SOFTWARE.tsv`。其中 `ASSEMBLE_EXISTING_EXACT_EVIDENCE_FIRST` 保留每条原子文字：Settings/Today组合、旧日重置顺序、Theme启动韧性、empty/error/loading与完整业务隔离等，先检查已有019/020与最新精确node的覆盖；不得仅因未裁决就再要求全部重跑。', '', '静态/历史/governance声明分别保留原审查适用范围；最终Release动态产物、真实macOS13、物理屏幕/高刷新、系统权限/VoiceOver/reduced-motion以及final human acceptance/deployment仍独立，不由本表关闭。', '', '## 完整性和适用范围','', '`STAGE9_CLOSURE_RUN_CATALOG.json` 记录每个command/build/source/execution/raw/summary SHA、环境、输入差异与重建方法；`STAGE9_CLOSURE_RUN_METHODS.tsv` 保留所有raw节点及失败；`STAGE9_CLOSURE_PREDICATE_BINDINGS.tsv` 给出断言锚点和边界。未取得完整旧测试源码的EventQueue/Access节点明确为source unavailable，不用当前文本冒充旧输入。', '', '后续生产修复只列为current-source差异待有界适用性复审，不因纯test变化要求全产品重测。脚本不修改Swift活动源码、历史ledger、Review、授权或验收状态。','']
(R/'STAGE9_CLOSURE_EVIDENCE_REPORT.md').write_text('\n'.join(lines))
