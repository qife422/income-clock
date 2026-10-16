#!/usr/bin/env python3
"""Recompute the Stage 9 view without modifying historical ledgers or seals.

Historical acceptance and current applicability are separate columns.  A fresh
run never becomes a pass by test name: a reviewed per-atomic mapping is required.
This generator only reads text evidence; it never opens an xcresult bundle.
"""
from pathlib import Path
import csv, hashlib, json, re, collections
ROOT=Path(__file__).resolve().parents[1]
INPUTS=ROOT.parent/'可视收入打卡机_review_inputs'
LEDGER=INPUTS/'stage9-s9r001-evidence-consistency-repair-2026-08-24-001/Evidence/Ledger'
BASE=INPUTS/'stage9-internal-release-qa-2026-08-21-001/Project'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p): return list(csv.DictReader(Path(p).open(),delimiter='\t'))
def write(p,rows):
    with Path(p).open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]),delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(rows)
def same(rel):
    a,b=ROOT/rel,BASE/rel
    return a.is_file() and b.is_file() and sha(a)==sha(b)
canonical=read(LEDGER/'STAGE9_CONTRACT_REQUIREMENT_COVERAGE_LEDGER.tsv')
gates=read(LEDGER/'STAGE9_DERIVED_GATE_LEDGER.tsv')
registry={r['evidence_id']:r for r in read(LEDGER/'STAGE9_PER_ASSERTION_EVIDENCE_REGISTRY.tsv')}
remaining={r['atomic_requirement_id']:r for r in read(ROOT/'STAGE9_REMAINING_COVERAGE_MATRIX.tsv')}
assert len(canonical)==370 and len(gates)==12 and len(remaining)==357
assert sha(LEDGER/'STAGE9_CONTRACT_REQUIREMENT_COVERAGE_LEDGER.tsv')=='c238f9de3af033bee80978145c518a9e70c86a05e1ab251904bf04a41bfc68de'
assert sha(LEDGER/'STAGE9_DERIVED_GATE_LEDGER.tsv')=='18c0c2198d5302fff0fce14758fb0d5519d2b73508b1f6295aa9a0adb1a1584b'
# Exact approved bodies, allowing the recorded review -> approved frontmatter.
manifest=ROOT/'contract_snapshots/2026-08-17-pd2rr-007-recovery-transaction-repair-candidates/SHA256SUMS'
assert sha(manifest)=='10d994a8ca452aaba742c0e6de25fd763f3ea6d42d826c42918e87fb4eaed150'
for line in manifest.read_text().splitlines():
    digest,rel=line.split(maxsplit=1);p=manifest.parent/rel.lstrip('*')
    assert sha(p)==digest
    active=ROOT/(p.name.split('-')[0]+'.md')
    assert active.is_file()
    assert active.read_text().split('---',2)[-1]==p.read_text().split('---',2)[-1]
reviews={
1:'STAGE9_BATCH_B1_T001_EARNINGS_FRESH_VALIDATION_INDEPENDENT_REVIEW.md',
2:'STAGE9_BATCH_B2_T002_STATE_DERIVER_FRESH_VALIDATION_INDEPENDENT_REVIEW.md',
3:'STAGE9_BATCH_C1_T003_CURRENT_DATE_CLOCKIN_TEST_REPAIR_INDEPENDENT_REVIEW.md',
4:'STAGE9_T004_DATE_RELATIONSHIP_TEST_ONLY_REPAIR_INDEPENDENT_REVIEW.md',
5:'STAGE9_BATCH_B5_T005_TODAY_VALIDATION_INDEPENDENT_REVIEW.md',
6:'STAGE9_BATCH_B6_T006_LOCAL_SCHEDULE_RESOLVER_VALIDATION_INDEPENDENT_REVIEW.md',
7:'STAGE9_BATCH_B7_T007_FORMATTERS_ODOMETER_VALIDATION_INDEPENDENT_REVIEW.md',
8:'STAGE9_BATCH_B8_T008_THEME_VALIDATOR_VALIDATION_INDEPENDENT_REVIEW.md',
9:'STAGE9_BATCH_B9_T009_COMMAND_PERSISTENCE_VALIDATION_INDEPENDENT_REVIEW.md',
10:'STAGE9_T010_TYPED_LOAD_PREACTION_REPAIR_INDEPENDENT_REVIEW.md',
11:'STAGE9_T011_SETTINGS_CONFLICT_TEST_ONLY_REPAIR_INDEPENDENT_REVIEW.md',
12:'STAGE9_T012_POSTCOMMIT_PUBLICATION_TEST_EVIDENCE_REPAIR_INDEPENDENT_REVIEW.md',
13:'STAGE9_T013_SETTINGS_COMMAND_CONTEXT_TEST_ONLY_REPAIR_INDEPENDENT_REVIEW.md'}
for p in reviews.values(): assert (ROOT/p).exists() and 'READY' in (ROOT/p).read_text()
# Minimal behavior dependencies for scoped reuse. Test identities are preserved
# by the cited independent adjudication; this pass additionally checks source
# compatibility with the earlier immutable product, and never widens its claim.
domain=[str(p.relative_to(ROOT)) for p in (ROOT/'IncomeClock/Domain').glob('*.swift')]
theme=['IncomeClock/Application/ThemeModels.swift','IncomeClock/Infrastructure/Theme/BundledThemeCatalog.swift','IncomeClock/Infrastructure/Theme/ThemePackageValidation.swift','IncomeClock/Infrastructure/Theme/ThemeRepository.swift','IncomeClock/Application/ThemeImportModels.swift']
reuse={1:domain,2:domain,5:domain+['IncomeClock/Infrastructure/Persistence/PersistenceRecords.swift'],6:domain+['IncomeClock/Application/BusinessWorkdayCalendar.swift'],8:theme}
# Governance clauses previously blocked solely because their referenced hardware
# gate was open are statically checkable. They do NOT close the hardware gate.
governance={'T-029.a','T-051.a','T-053.a','UI18-052.a','UI18-053.a','UI18-054.a','UI18-055.a','UI18-056.a','UI18-057.a'}
# Plan candidates only, not assertion coverage conclusions.
critical_gaps={'T-014.a':'Actual terminated child process + fresh restore process; Presentation publication observer; direct repository/temporary-write counters or write syscall trace. Same-process reconstruction, static View mapping and bytes equality alone are insufficient.',
'T-015.a':'Demonstrate restore, refresh, date-transition and timezone-change error entry; loading ends, nil ViewState, unchanged records, failed then successful retry.',
'T-016.a':'Every startToday preflight failure must have direct zero delete/save counters and exact old bytes/revision/ViewState retention, then single CAS success/conflict/delete-failure coverage.',
'T-017.a':'Complete damaged Settings x Today matrix, cancel/failure/success reset/replacement, every replacement checkpoint, zero temporary writes and postcommit fail-on-call traps.',
'T-018.a':'Both reset orders AND replacement order with direct main/secondary errors, bytes preserved at every step, final state matrix.'}
rows=[]
for index,c in enumerate(canonical,2):
    rid=c['sub_requirement_id'];old=c['status'];plan=remaining.get(rid)
    cat={'2':'B','3':'C','5':'D','6':'D','7':'D','8':'D','9':'E'}.get(plan['category'],'B') if plan else 'B'
    current='NOT_VERIFIED';hist=old;reason=c['disposition_reason'];review='';evidence='';binding=c['assertion_bindings'];deps=[]
    if plan:
        reason=plan['currently_cannot_prove'];evidence=plan['exact_evidence_path']
    if cat=='D': current='BLOCKED';reason=plan['required_direct_evidence']+' | '+plan['currently_cannot_prove']
    if rid in governance:cat='B';current='NOT_VERIFIED';reason='Governance assertion can be checked statically; its referenced real hardware gate remains independently blocked.'
    if rid == 'P22-030.a':
        cat='C';current='NOT_VERIFIED';reason='Producer scope correction: first/default main-screen placement is testable on the current display, equivalent to P21-005.a; external display matrix remains blocked. Independent applicability review pending.'
    if rid in {'P21-005.a','P21-006.a','P21-007.a','P21-008.a','P21-086.file_chooser','P22-038.a','UI18-049.decorative_tree'}:
        cat='C';current='NOT_VERIFIED';reason='2026-09-07 independent reviewer scope correction: this atomic behavior can be exercised on current single display or temporary package fixture without changing hardware/system preferences. Add direct real-product interaction/observation; S4R-003 and real accessibility setting gates remain separate.'

    match=re.fullmatch(r'T-(\d{3})\.a',rid)
    if match and int(match[1]) in reviews:
        num=int(match[1]);review=str(ROOT/reviews[num]);hist='FRESH_PASS_ACCEPTED_OVERLAY';evidence=review
        reason='Historical separated reviewer accepted only this atomic requirement. Current edited dependencies require fresh mapped evidence unless scoped identity is established.'
        if num in reuse:
            deps=reuse[num]
            if all(same(p) for p in deps):cat='A';current='REUSABLE_SCOPED_PASS';reason='Accepted independent atomic overlay + unchanged listed behavior dependencies; retain historical environment and test scope, no extension to UI/process/system gates.'
    if rid=='P21-112.a':
        review=str(ROOT/'STAGE9_BATCH_J_P21112_NA_DISPOSITION_INDEPENDENT_REVIEW.md');cat='E';hist='CONTRACT_SUPPORTED_NA_ACCEPTED_OVERLAY';current='CONTRACT_SUPPORTED_NA';evidence=review;reason='Product §20.8 first-release future-capability exclusion; independent Batch J adjudication; no N/A beyond this atomic row.'
    if old=='HISTORICAL_BOUND_EVIDENCE':
        cat='A';current='HISTORICAL_BOUND_EVIDENCE';reason='Historical inspection of exactly five preview PNGs only; not current runtime or full matrix validation.'
    ids=c['evidence_ids'].split(';') if c['evidence_ids'] else []
    raw=[]
    for eid in ids:
        e=registry.get(eid)
        if e:
            raw.extend(filter(None,[e['raw_result_path'],e['test_source_path'],e['static_raw_paths']]))
    if raw:evidence='; '.join(raw)
    # Pure Theme policy/contrast observations have unchanged data/validators and
    # unchanged test file; keep the very narrow historical assertion boundary.
    if ids and all(e.startswith(('TEST-REDUCE-MOTION-POLICY','TEST-THEME-ACTION-TEXT-CONTRAST','TEST-THEME-FOCUS-RING-CONTRAST')) for e in ids):
        deps=theme+['IncomeClockApplicationTests/ThemeStoreTests.swift']
        if all(same(p) for p in deps):cat='A';current='REUSABLE_SCOPED_PASS';reason='Exact canonical assertion binding; unchanged Theme behavior dependencies and test file. No real OS accessibility or whole-view contrast claim.'
    if rid in critical_gaps:cat='C';current='NOT_VERIFIED';reason=critical_gaps[rid]
    source=ROOT/c['source'];line=int(c['line']);source_line=source.read_text().splitlines(keepends=True)[line-1]
    if plan:assert hashlib.sha256(source_line.encode()).hexdigest()==plan['contract_source_line_sha256']
    rows.append(dict(row_kind='CONTRACT',atomic_requirement_id=rid,original_requirement_id=c['original_requirement_id'],contract_source=f"{c['source']}:{line}",contract_line_sha256=hashlib.sha256(source_line.encode()).hexdigest(),atomic_requirement=c['atomic_requirement'],canonical_ledger=str(LEDGER/'STAGE9_CONTRACT_REQUIREMENT_COVERAGE_LEDGER.tsv'),canonical_row=index,historical_disposition=hist,category=cat,current_disposition=current,batch=('external-gates' if cat=='D' else 'theme-security' if any(s in c['atomic_requirement'].lower() for s in ['theme','皮肤','capability','profile','manifest']) else 'business-persistence' if c['source']!='UI_SPEC.md' and cat!='C' else 'presentation-and-lifecycle'),assertion_or_required_observation=binding or (plan['required_direct_evidence'] if plan else c['atomic_requirement']),evidence_paths=evidence,independent_review=review,compatibility_dependencies='; '.join(f'{p}#{sha(ROOT/p)}' for p in deps),limitation_or_close_condition=reason,review_status='awaiting_consolidated_independent_review' if cat!='D' else 'blocked_external_gate'))
for index,g in enumerate(gates,2):
    p=remaining[g['gate_id']];cat='B' if p['category']=='2' else 'D'
    rows.append(dict(row_kind='GATE',atomic_requirement_id=g['gate_id'],original_requirement_id=g['original_requirement_id'],contract_source=g['contract_source_binding'],contract_line_sha256='',atomic_requirement=g['gate_text'],canonical_ledger=str(LEDGER/'STAGE9_DERIVED_GATE_LEDGER.tsv'),canonical_row=index,historical_disposition=g['status'],category=cat,current_disposition='BLOCKED' if cat=='D' else 'NOT_VERIFIED',batch='external-gates' if cat=='D' else 'release-static',assertion_or_required_observation=p['required_direct_evidence'],evidence_paths='',independent_review='',compatibility_dependencies='',limitation_or_close_condition=p['currently_cannot_prove'],review_status='blocked_external_gate' if cat=='D' else 'awaiting_consolidated_independent_review'))
assert len(rows)==382 and len({x['atomic_requirement_id'] for x in rows})==382
for row in rows:
    row['canonical_atomic_requirement']=row['atomic_requirement']
    row['projection_correction']=''
    row['supplemental_contract_binding']=''
    if row['atomic_requirement_id']=='P21-015.shortcut_show':
        row['atomic_requirement']='Explicit user shortcut shows the real panel and permits deliberate keyboard focus; ordinary programmatic/menu display remains non-activating.'
        row['assertion_or_required_observation']='Real shortcut entry displays the panel and deliberately requests keyboard focus per UI_SPEC §17.1; do not assert that Finder must remain frontmost for an explicit focus shortcut.'
        row['projection_correction']='2026-09-07 consolidated reviewer identified canonical English overrestriction. Canonical row preserved verbatim in canonical_atomic_requirement; successor projection corrected against Approved Product non-arbitrary-focus rule and UI explicit-shortcut-focus rule; no Contract change.'
        text=(ROOT/'UI_SPEC.md').read_text().splitlines(keepends=True)[752]
        row['supplemental_contract_binding']='UI_SPEC.md:753#'+hashlib.sha256(text.encode()).hexdigest()
        row['limitation_or_close_condition']='Observe real user shortcut and focused panel; ordinary-show Finder-frontmost assertion is separately retained at P21-015.ordinary_show. Independent reviewer must confirm projection correction.'
write(ROOT/'STAGE9_CLOSEOUT_DISPOSITION.tsv',rows)
# Complete C work list, preserving requirement-specific semantics.
write(ROOT/'STAGE9_CLOSEOUT_GAPS.tsv',[r for r in rows if r['category']=='C'])
# Read-only source catalog: method text and assertions are locators, never PASS.
catalog=[]
for p in sorted(ROOT.glob('*Tests/*.swift')):
    lines=p.read_text().splitlines(keepends=True)
    starts=[i for i,l in enumerate(lines) if re.match(r'    func test\w+',l)]
    for i in starts:
        j=i+1
        while j<len(lines) and not re.match(r'    }\s*$',lines[j]): j+=1
        text=''.join(lines[i:j+1]);name=re.search(r'func (test\w+)',lines[i])[1]
        catalog.append(dict(test_file=str(p.relative_to(ROOT)),method=name,start_line=i+1,end_line=j+1,method_sha256=hashlib.sha256(text.encode()).hexdigest(),assertion_anchors=' | '.join(f'{i+k+1}:{l.strip()}' for k,l in enumerate(lines[i:j+1]) if 'XCTAssert' in l or 'XCTFail' in l),evidence_status='SOURCE_LOCATOR_ONLY_NOT_EXECUTION_OR_COVERAGE'))
write(ROOT/'STAGE9_CLOSEOUT_TEST_CATALOG.tsv',catalog)
summary=dict(contract_rows=370,gate_rows=12,total_rows=len(rows),categories=dict(collections.Counter(r['category'] for r in rows)),current_dispositions=dict(collections.Counter(r['current_disposition'] for r in rows)),historical_canonical_counts=dict(collections.Counter(c['status'] for c in canonical)),accepted_technical_overlays=13,accepted_na_overlays=1,test_catalog_methods=len(catalog),canonical_ledger_sha256=sha(LEDGER/'STAGE9_CONTRACT_REQUIREMENT_COVERAGE_LEDGER.tsv'),canonical_gate_sha256=sha(LEDGER/'STAGE9_DERIVED_GATE_LEDGER.tsv'),approved_manifest_sha256=sha(manifest),limitations=['Development analysis, not independent adjudication.','A is scoped reuse, B remains not verified until direct bindings are supplied.','Historical canonical ledger and review inputs were never mutated.'])
(ROOT/'STAGE9_CLOSEOUT_COVERAGE_SUMMARY.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(summary,ensure_ascii=False,indent=2))
