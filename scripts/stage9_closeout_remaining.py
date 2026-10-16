#!/usr/bin/env python3
"""Project existing unresolved predicates into the eight existing shared packages.

This is development evidence planning, not Review or runtime adjudication. No
suite status is read. Direct candidates stay pending until exact run binding and
independent sufficiency/compatibility review. Historical inputs are read-only.
"""
from pathlib import Path
import csv, collections, json, hashlib
ROOT = Path(__file__).resolve().parents[1]
def read(name):
    with (ROOT/name).open() as f: return list(csv.DictReader(f, delimiter='\t'))
rows = read('STAGE9_CLOSEOUT_DISPOSITION.tsv')
links = read('STAGE9_CLOSEOUT_ASSERTION_CANDIDATES.tsv')
static = read('STAGE9_CLOSEOUT_STATIC_OBSERVATIONS.tsv')
bindings = read('STAGE9_CLOSEOUT_RUN_BINDINGS.tsv')
selected = [b for b in bindings if b['selected_for_current']=='True']
direct = {r['atomic_requirement_id'] for r in links if r['coverage_scope']=='direct_atomic_candidate'}
static_direct = {r['atomic_requirement_id'] for r in static if r['scope'].startswith('DIRECT_') or r['scope']=='SOURCE_ONLY'}
groups = {}
def group(name, ids):
    for rid in ids.split():
        assert rid not in groups, rid
        groups[rid] = name
group('1-settings-transactions-recovery', '''P21-017.a P21-019.a P21-020.a P21-021.a P21-049.a P21-050.a P21-053.a P21-054.a P21-055.a
P22-014.a P22-015.a P22-016.a P22-018.a P22-019.a P22-025.a P22-026.a P23-07.a T-017.a T-019.a T-039.a
UI18-012.a UI18-013.a UI18-014.a UI18-016.a UI18-017.a UI18-018.a UI18-019.a UI18-020.a UI18-021.a UI18-022.a UI18-037.a UI18-038.a UI18-039.a UI18-041.business_retry UI18-041.real_settings_flow''')
group('2-theme-lifecycle-isolation', '''P21-087.a P21-091.a P21-092.a P21-093.a P21-094.a P21-095.a P21-096.a
P22-045.a P22-046.a P22-047.a P22-048.a P22-049.a P22-050.a P22-056.a P22-057.a P22-058.a P23-09.a
T-022.a T-062.a T-063.a UI18-003.business_state UI18-042.management_ui UI18-044.a UI18-045.a''')
group('3-keyboard-disabled-escape', '''P21-080.keyboard P21-098.keyboard_focus UI18-003.focus_order UI18-036.keyboard_all_pages UI18-050.focus_escape UI18-050.disabled_reason''')
group('4-native-menu-single-screen', '''P21-005.a P21-006.a P21-007.a P21-008.a P21-012.close_does_not_quit_app P21-015.shortcut_show
P21-024.a P21-041.panel_reshow P21-060.a P21-071.a P21-073.status_summary P21-073.open_settings P21-073.quit P21-074.a P21-075.a
P22-005.a P22-030.a T-024.shared_state T-024.other_flows UI18-028.background_recalibration UI18-035.order_and_summary''')
group('5-panel-visual-matrix', '''P21-028.a P21-031.a P21-037.a P21-038.a P21-039.a P21-043.a P21-080.non_color P21-081.a P21-082.a P21-084.a
P21-098.non_color P21-098.remaining_text_nontext_contrast P21-099.runtime_matrix P21-110.a
P22-003.a P22-004.a P22-054.a P23-04.settings P23-06.complete_light_dark P23-06.text_120
UI18-001.a UI18-002.a UI18-003.panel_size UI18-006.a UI18-008.a UI18-009.a UI18-027.a UI18-030.a UI18-031.a UI18-032.a UI18-033.a UI18-034.a UI18-036.minimum_size UI18-047.a UI18-049.decorative_tree UI18-051.a''')
group('6-theme-entry-success-error-empty', '''P21-086.browse P21-086.file_chooser P21-086.drag_drop P22-038.a UI18-043.a UI18-046.a''')
group('7-release-local-offline', '''P21-001.macos13_declaration P23-04.macos13_declaration T-045.universal_app T-046.a T-047.a T-064.sandbox X-006.a''')
group('8-static-provenance-governance', '''P21-002.a P21-003.a P21-004.a P21-025.a P21-102.a P21-104.a P21-105.a P22-037.a P22-060.a P22-061.a P22-063.a P22-064.a
T-008.a T-048.a T-050.a T-051.a T-052.a T-053.a T-059.a T-060.a UI18-005.a UI18-035.no_animation_character UI18-052.a UI18-053.a UI18-054.a UI18-055.a UI18-056.a UI18-057.a''')
# Direct candidates still need executed current methods; static observations need
# their separate identity/sufficiency review. Neither disappears from this queue.
for rid in '''P21-001.menu_bar_runtime P21-015.ordinary_show P21-016.menu P21-016.shortcut P21-046.a P21-058.a
P21-073.panel_toggle P22-006.a P23-04.panel P23-04.menubar T-024.menubar_toggle T-024.shortcut_toggle
UI18-010.live_estimate UI18-035.toggle_title'''.split(): groups[rid]='4-native-menu-single-screen'
for rid in '''P21-109.a P23-08.a T-028.a T-029.a T-045.deployment_target T-049.a T-058.automated_single_display UI18-004.a'''.split(): groups[rid]='8-static-provenance-governance'
notes = {
'1-settings-transactions-recovery': 'Combine named preflight/revision/postcommit methods with hosted checking/saving/error and actual UI reset/retry. The 12 hosted conflict/I-O cases do not themselves observe every preflight input, full Panel/MenuBar error matrix, or every old-day delete success/failure surface.',
'2-theme-lifecycle-isolation': 'Candidate019 binds the real EARNING Theme trajectory, installed-package revalidation/fallback and fresh-process user-theme restore to exact Passed methods; production launch-path changes after019 still need compatibility review. P21-094 also lacks an immediate post-restoreDefault assertion of persisted selectedThemeId and actual effectiveTheme; the later delete-failure persistence assertion cannot prove it. Remaining actions include actual UI reinstall/upgrade/rejection/noncurrent deletion; builtin/current/installed controls are added but their isolated UI run is pending.',
'3-keyboard-disabled-escape': 'Candidate019 sidebar routing and focused-shortcut negative test Passed; two whole-page native keyboard methods Failed while macOS Keyboard navigation is off. Do not treat this as acceptance or silently change the system setting. Conditional import/lifecycle/damaged-Settings controls, cross-theme focus order and every disabled reason remain incomplete.',
'4-native-menu-single-screen': 'Existing real hidden panel maintenance and hosted Menu seven-state/recovery/loading methods have exact019 Passed nodes. Added actual menu Settings/clock-in/clock-out/quit and primary-display drag/reset/lock-click actions await the isolated native UI run. Actual menu visual order/separators/shortcuts/checked toggle values and continuing countdown/inactive return remain distinct observations; fake screens do not close them.',
'5-panel-visual-matrix': 'Candidate020 exact render method Passed after correcting test height to real glyph geometry;019 failed result stays retained. Bind its28 state/theme/appearance images and named019 carry/settlement frames to specific clauses. Wider gaps include Settings/error surfaces, non-primary contrast, actual interaction during active animation and whole-product Light/Dark/120percent checks.',
'6-theme-entry-success-error-empty': 'Actual file chooser test is pending an isolated runner; drag-drop entry has no corresponding native gesture test. Hosted error/empty/toast/committing tests cover their exact controls; consolidate error/reselection and lifecycle alternatives without treating Store calls as UI gestures.',
'7-release-local-offline': 'Inspect the actual current Release bundle/configuration and run isolated offline/no-network behavior. Debug/ad-hoc test runner or pbx source declarations do not prove Release architecture/effective entitlements or offline runtime. No signing/distribution authorization implied.',
'8-static-provenance-governance': 'Finish exact source/dependency closure, complete user-string inventory and current/historical governance gate references. Capability rejection diagnostics use named corpus; static no-execution/no-network claims require the actual closed source set, not keyword absence alone.'}
# Advisory closure planning does not mutate runtime or independent dispositions.
# These routes separate missing execution from sufficient existing clauses that
# still need current-input/atomic assembly. Never count route totals as PASS.
review_file = ROOT/'STAGE9_CLOSEOUT_BATCH_REVIEW.md'
review_sha = hashlib.sha256(review_file.read_bytes()).hexdigest()
review_line = next(i for i,line in enumerate(review_file.read_text().splitlines(),1) if line.startswith('## 追加独立复审：36项静态候选'))
static_candidate = json.loads((ROOT/'STAGE9_CLOSEOUT_STATIC_CANDIDATE.json').read_text())
static_by_id = {r['atomic_requirement_id']: r for r in static_candidate['observations']}
routes = {}
def route(ids, kind, action, predicate, scope='', fresh='only_if_existing_predicate_is_unproved'):
    for rid in ids.split():
        assert rid not in routes, ('duplicate closure route', rid)
        routes[rid] = dict(closure_route=kind, minimal_action_group=action,
            minimum_remaining_predicate=predicate, reviewed_scope=scope,
            fresh_runtime_needed=fresh)
route('P21-002.a P21-004.a', 'REVIEWED_STATIC_CLAUSE', 'S-native-boundary',
      'Carry forward native/no-web/no-widget source boundary; inspect final bundle separately under Release IDs. Do not add tests for the source declaration.',
      '023 native source/PBX/package graph accepted; current unrelated diagnostic delta needs bounded graph compatibility acknowledgement.', 'no_for_this_static_clause')
route('P21-102.a T-050.a', 'REVIEWED_STATIC_CLAUSE', 'S-theme-closure',
      'Recheck only changed compatibility diagnostic closure and preserve no Theme execution/network-loader boundary; corpus/offline/artifact requirements stay separate.',
      '023 scoped Theme validation/media/runtime closure accepted; not whole-app offline or all malicious-input execution.', 'no_for_this_static_clause')
route('P21-104.a P22-060.a', 'REVIEWED_STATIC_CLAUSE', 'S-capability-registry',
      'Confirm S9C-006 diagnostic-only delta preserves standard-theme@1 required registry and optional-ignore behavior.',
      '023 actual capability/default runtime registry accepted; no future capability implied by stored manifest fields.', 'no_for_this_static_clause')
route('P21-109.a UI18-004.a', 'REVIEWED_STATIC_CLAUSE', 'S-profile-direction',
      'Reuse Profile-to-Presentation dependency direction; keep dynamic changed-Profile comparison under P22-064.',
      '023 Profile constants absent from Domain/Business/authoritative records; source boundary accepted.', 'no_for_this_static_clause')
route('P23-08.a', 'REVIEWED_STATIC_CLAUSE', 'S-doc-limits',
      'Reuse current matching README local-data/device-clock/notification-limits paragraphs.',
      'Document declaration accepted, not actual notification delivery.', 'no_for_this_static_clause')
route('T-008.a', 'REVIEWED_STATIC_CLAUSE', 'S-validator-delta',
      'Rebind changed validateCompatibility fragment and called diagnostic value helpers; retain exclusions for repository I/O and Bundle resource helper.',
      '023 named validator closure accepted; S9C-006 changed function must receive delta review.', 'no_for_this_static_clause')
route('T-028.a', 'REVIEWED_STATIC_CLAUSE', 'S-checklist-identity',
      'Recompute unique/disjoint 370+12 ID set equality against 382 current rows after final projection; no per-ID acceptance inferred.',
      'Checklist set structure accepted.', 'no_for_this_static_clause')
route('T-045.deployment_target', 'REVIEWED_STATIC_CLAUSE', 'S-deployment-declaration',
      'Reuse matching PBX 13.0 declaration; Release load commands and real macOS13 are separate IDs.',
      'Source deployment-target declaration accepted.', 'no_for_this_static_clause')
route('T-048.a T-049.a', 'REVIEWED_STATIC_CLAUSE', 'S-system-adapters',
      'Reuse matching production notification/SMAppService API closure and absent privileged-install/permission-request paths; leave actual system outcomes at their own gate.',
      'Production API implementation accepted; UI automation permissions are test-only.', 'no_for_this_static_clause')
route('UI18-005.a UI18-035.no_animation_character', 'REVIEWED_STATIC_CLAUSE', 'S-presentation-scope',
      'Reuse standard-only Profile negotiation or native menu no-animation/no-character closure; does not prove real menu ordering or countdown.',
      '023 specific production source scope accepted.', 'no_for_this_static_clause')
route('T-029.a T-051.a T-052.a UI18-052.a UI18-053.a UI18-055.a', 'REVIEWED_GOVERNANCE_CLAUSE', 'S-current-gates',
      'Re-read active state after explicit supplement; retain seven-axis separation, S4R-003 DEFERRED, full physical matrix and no RC/deployment without evidence.',
      'Governance semantics accepted; mutable state SHA needs current rebind. No physical behavior PASS.', 'no_for_this_governance_clause')
route('T-053.a T-058.automated_single_display T-059.a UI18-056.a UI18-057.a', 'REVIEWED_HISTORICAL_CLAUSE', 'S-historical-gates',
      'Preserve original Stage4/4D/Stage5 authorization and review chain; confirm referenced records still match without rerunning or repackaging old raw.',
      'Historical chain/limited automated-single-display records accepted; never current source or fresh authorization.', 'no_for_this_historical_clause')
route('P21-003.a', 'NATIVE_UI_EVIDENCE_REQUIRED', 'U-menu-panel',
      'Observe actual default agent launch has no Dock icon, in addition to accepted LSUIElement declaration.',
      '023 source declaration only.', 'yes_actual_native_observation')
route('P21-025.a P22-037.a', 'COPY_AUDIT_COMPLETION', 'S-visible-copy',
      'Complete first-party rendered/dynamic string inventory including changed compatibility diagnostics, format interpolation and resources; preserve external Theme content distinction. Review existing page captures first.',
      '023 quoted/CJK/forbidden-phrase scan accepted only as partial observation.', 'no_new_runtime_unless_dynamic_surface_unobserved')
route('P21-105.a P22-061.a P21-094.a', 'AUTHORIZED_REPAIR_RUN_REQUIRED', 'R-five-theme-selectors',
      'Run four concrete compatibility diagnostic fixtures plus modified same-phase restoreDefault durable selected/effective test from STAGE9_COMPATIBILITY_DIAGNOSTIC_REPAIR.json; bind new exact methods/helper/source before S9C-006/007 review.',
      '023 diagnosed gap; later repair parse-only, no inherited PASS.', 'yes_existing_repair_selectors')
route('P22-063.a P22-064.a', 'CONTROLLED_SOFTWARE_OBSERVATION_MISSING', 'R-profile-mask-equivalence',
      'Use the same authoritative input trace with a changed standard Profile, and separately optional mask + validated standard fallback; compare full Store/state/timestamps/notifications/persisted bytes/amount and hit regions. Theme switching and static no-read proof alone do not meet this predicate.',
      '36-item review: optional mask partial; changed-Profile dynamic comparison absent.', 'yes_narrow_missing_equivalence_evidence')
route('UI18-054.a', 'REAL_EXTERNAL_GATE', 'G-physical-display',
      'Actual external-display full matrix remains required; remove from software execution worklist only, never mark passed or close S4R-003.',
      '36-item review explicitly rejects policy reading as physical completion.', 'real_external_environment_only')
route('T-060.a', 'REVIEW_EXISTING_RUNTIME_FIRST', 'E-stage5-current',
      'Assemble current A UI/amount and actual ReduceMotion/VoiceOver evidence; the historical Stage5 verified record proves only history and cannot close current matrix.',
      'Only Stage5 historical verified record confirmed.', 'only_for_uncovered_current_or_system_clause')
route('P21-017.a P21-024.a P21-075.a P21-080.keyboard P21-098.keyboard_focus UI18-003.focus_order UI18-036.keyboard_all_pages UI18-050.focus_escape UI18-050.disabled_reason',
      'NATIVE_UI_EVIDENCE_REQUIRED', 'U-keyboard-seven-pages',
      'Run existing native keyboard methods after authorized setting readback; exercise seven pages plus conditional Theme import/recovery controls, A/B focus order, Space/Return and Escape/disabled reasons. Include real toggles without claiming login registration/system outcomes from adapters.',
      '019 two keyboard methods failed; ordinary Tab routing and negative Space evidence remain separately valid.', 'yes_actual_keyboard_session')
route('P21-019.a P22-014.a P22-015.a UI18-037.a UI18-041.real_settings_flow',
      'NATIVE_UI_EVIDENCE_REQUIRED', 'U-dst-fields-startup-retry',
      'Execute existing gap start/end field preservation/focus check; add only missing November fold start/end and startup schedule-error -> Settings correction -> visible retry clearance. Assert no failed success announcement, same bytes/revision. Damaged Settings reset is a different flow.',
      'Business resolver/preflight tests already Passed; current native gap helper unproven, fold/startup actual flow absent.', 'yes_missing_native_fields_and_startup_flow')
route('P21-021.a P21-046.a P21-058.a P22-006.a T-024.shared_state T-024.other_flows UI18-010.live_estimate',
      'NATIVE_UI_EVIDENCE_REQUIRED', 'U-shared-business-flow',
      'First resolve literal HH:mm input then run existing Settings -> clock-in -> close Settings/continue -> confirmation live estimate/cancel/confirm -> menu quit/relaunch selectors, with same persisted Today and exact shared state; inspect login UI adapter only within this scope.',
      '021/022 input failures retained; 019 business/hosted/process paths do not substitute for T-024 XCUITest.', 'yes_existing_native_selectors')
route('P21-006.a P21-007.a', 'NATIVE_UI_EVIDENCE_REQUIRED', 'U-single-display-placement',
      'Reuse existing native primary-display drag/reset/lock-click selector; verify remaining three corner snaps/clamp plus restart/readback where required. One top-left drag is not four-corner coverage.',
      'Fake screen geometry/delegate tests are narrow existing evidence.', 'yes_remaining_real_single_display_gestures')
route('P21-041.panel_reshow P21-060.a P22-005.a UI18-028.background_recalibration',
      'NATIVE_UI_EVIDENCE_REQUIRED', 'U-background-return',
      'While earning hide panel and make app inactive; restore real panel and compare amount/countdown to current timestamp with no animation backlog. Reuse hidden maintenance method for its existing clause.',
      '019 hidden Panel maintenance evidence valid, actual inactive-return/countdown clause remains distinct.', 'yes_real_return_observation')
route('UI18-035.order_and_summary', 'NATIVE_UI_EVIDENCE_REQUIRED', 'U-menu-seven-state',
      'Inspect actual popover seven-state summary/order/Divider/shortcut labels/toggle checked values and enabled actions; reuse 019 hosted seven-state text/value assertions instead of recreating Store matrix.',
      '019 hosted menu seven states Passed; not a popover visual/action audit.', 'yes_actual_popover_observation')
route('P21-071.a', 'REVIEW_EXISTING_RUNTIME_FIRST', 'E-notification-isolation',
      'Assemble notification-denial/scheduling-error adapter results with authoritative end and in-app reminder behavior; actual system suppression/delivery remains system gate, no extra fake test solely for count.',
      'Do not conflate no business dependency with proof of actual notification delivery.', 'only_for_uncovered_actual_system_clause')
route('P21-084.a', 'CONTROLLED_SOFTWARE_OBSERVATION_MISSING', 'R-active-animation-click',
      'Observe primary clock-out during a proven active production animation (activeAnimationCount > 0 at input), then actual confirmation/settlement. Current carry test uses invisible pulse and post-render AXPress, so does not prove this timing.',
      '019 carry geometry/AXPress after render remains valid but partial.', 'yes_narrow_active_animation_input')
route('P21-081.a P21-082.a P21-098.remaining_text_nontext_contrast P21-099.runtime_matrix P23-06.complete_light_dark P23-06.text_120 UI18-047.a UI18-051.a',
      'VISUAL_GAP_AFTER_EXISTING_REVIEW', 'V-cross-surface',
      'Reuse already reviewed Panel 28-state images/020 glyph assertions and six019 settlement/confirmation images. Check only missing Settings/menu/error/focus/non-primary-control contrast, Light/Dark/120percent states and clipping; do not export/rebuild the proven panel matrix.',
      'Panel matrix is not full-product matrix; concrete missing surfaces remain.', 'only_missing_surface_samples')
route('P23-04.settings UI18-036.minimum_size', 'VISUAL_GAP_AFTER_EXISTING_REVIEW', 'V-settings-minimum',
      'Existing 680x500 render confirms fittingSize minimum only; inspect seven actual Settings pages and conditional errors at minimum size with core frame/text containment. Combine with keyboard session; retain only named missing views.',
      'testSettingsWindowRendersAllNavigationAtMinimumSize is not all-page no-clipping proof.', 'only_missing_page_or_error_sample')
route('UI18-001.a', 'REVIEW_EXISTING_VISUAL_FIRST', 'V-scale-geometry',
      'Inspect existing image/geometry metadata for both 1x and 2x 320x190pt with safe-area frames; existing actual2x alone cannot certify1x. Add only missing scale evidence, not real display-rate simulation.',
      'Standard Profile source and geometry assertions already bound.', 'only_if_one_required_scale_missing')
route('UI18-049.decorative_tree', 'REVIEW_EXISTING_VISUAL_FIRST', 'V-decoration-accessibility',
      'Combine existing hosted actual AX-tree checks for EARNING and settlement with source decoration accessibility-hidden/hit-testing boundary; inspect remaining visible B decoration states only if reviewer cannot close exact scope.',
      'No blanket accessibility-tree conclusion from model flags.', 'only_unobserved_decorative_state')
route('P21-086.browse P21-086.file_chooser P21-086.drag_drop P22-038.a P22-045.a P22-046.a P22-047.a P22-048.a UI18-042.management_ui',
      'NATIVE_UI_EVIDENCE_REQUIRED', 'U-theme-lifecycle',
      'Run existing system chooser -> preview -> install -> explicit use -> current-delete fallback selector; supplement actual drag-drop, same-version reinstall, upgrade/rejection and non-current delete/built-in disabled paths. Reuse repository security/atomic cases; do not duplicate them as UI tests.',
      'File chooser and real lifecycle are not proved by Store/repository invocation.', 'yes_minimal_native_lifecycle')
route('UI18-044.a UI18-045.a P21-092.a', 'NATIVE_UI_EVIDENCE_REQUIRED', 'U-theme-earning',
      'During shared earning session preview without apply, switch A/B and installed Theme, show matching Panel/Menu/Settings selected/effective state and continuous amount, then current-delete fallback. Reuse019 complete business/notification trajectory.',
      '019 Theme trajectory accepted narrowly; actual visible transition still required.', 'yes_shared_native_earning_session')
# Remaining rows default to evidence assembly, not a request for new tests.
def closure_plan(r):
    rid=r['atomic_requirement_id']
    if rid in routes: result=dict(routes[rid])
    elif groups[rid].startswith('7-'):
        result=dict(closure_route='RELEASE_ARTIFACT_EVIDENCE_REQUIRED', minimal_action_group='A-one-local-release',
            minimum_remaining_predicate='Use one sequential local Release artifact: effective build settings, universal slices/load commands/minimum OS, plist/nested executables/network/file entitlements and isolated offline exercise. DEBUG or source declaration cannot substitute; real macOS13 and distribution stay separate.',
            reviewed_scope='Existing source declarations only; no final Release result inherited.', fresh_runtime_needed='yes_artifact_inspection_or_isolated_offline')
    elif groups[rid].startswith('4-'):
        result=dict(closure_route='NATIVE_UI_EVIDENCE_REQUIRED', minimal_action_group='U-menu-panel',
            minimum_remaining_predicate='Run existing real menu/shortcut/native-panel selectors for this exact atomic requirement; combine ordinary Finder-focus behavior, shortcut focus, show/hide, open Settings/quit and primary placement/reset/lock-click in one fixture batch. Keep T-024 actual XCUITest requirement.',
            reviewed_scope='Native candidate methods exist; fake screen/hosted actions do not close actual gesture.', fresh_runtime_needed='yes_existing_native_selectors')
    elif groups[rid].startswith('5-'):
        result=dict(closure_route='REVIEW_EXISTING_VISUAL_FIRST', minimal_action_group='E-panel-existing-images',
            minimum_remaining_predicate='Assemble the exact model/token/resource/native-frame assertions with already-reviewed 017/019 images and020 glyph result for this atomic text. Name any remaining component/state/appearance before requesting a new sample; do not infer full sufficiency from image count.',
            reviewed_scope='Existing Panel narrow images/assertions are available; row remains unaccepted pending atomic assembly.', fresh_runtime_needed='only_if_specific_visual_clause_missing')
    else:
        result=dict(closure_route='REVIEW_EXISTING_RUNTIME_FIRST', minimal_action_group='E-existing-'+groups[rid].split('-')[0],
            minimum_remaining_predicate='Assemble listed exact019/020 method predicates, including related unmapped methods when necessary, against every clause of this atomic requirement. Preserve partial scope; only name a new execution when a concrete missing clause remains after this review.',
            reviewed_scope='Existing passed method evidence is not yet a full atomic adjudication; no new test implied by partial label.', fresh_runtime_needed='only_if_existing_predicate_is_unproved')
    observation=static_by_id.get(rid)
    changed=[]
    if observation:
        for item in observation['source_bindings'].split('; '):
            path,digest=item.rsplit('#',1);q=Path(path) if Path(path).is_absolute() else ROOT/path
            if not q.is_file() or hashlib.sha256(q.read_bytes()).hexdigest()!=digest:changed.append(path)
    result['row_applicability_reference']='STAGE9_CLOSEOUT_ROW_APPLICABILITY.json#'+rid if result['closure_route'].startswith('REVIEWED_') or result['closure_route'] in ('REVIEW_EXISTING_RUNTIME_FIRST','REVIEW_EXISTING_VISUAL_FIRST') else ''
    result.update(independent_review_reference='STAGE9_CLOSEOUT_BATCH_REVIEW.md:'+str(review_line) if observation or rid in ('P21-094.a',) else '',
        independent_review_sha256=review_sha if observation or rid=='P21-094.a' else '',
        reviewed_source_changed_files='; '.join(changed),
        projection_limit='Advisory execution/review routing only; no runtime PASS, atomic acceptance, Finding closure or authorization changes. Broad source-binding drift is not a per-clause incompatibility finding.')
    return result
out=[]
for r in rows:
    rid=r['atomic_requirement_id']
    if r['category'] not in ('B','C') or r.get('producer_run_disposition')=='PRODUCER_PASS_CANDIDATE': continue
    assert rid in groups, ('unclassified', rid)
    relevant=[a for a in links if a['atomic_requirement_id']==rid]
    raw=[b for b in selected if b['atomic_requirement_id']==rid]
    gap_kind='DIRECT_CANDIDATE_AWAITS_CURRENT_RUN' if rid in direct else 'STATIC_OBSERVATION_AWAITS_REVIEW' if rid in static_direct else 'INCOMPLETE_ATOMIC_PREDICATE'
    out.append(dict(atomic_requirement_id=rid,shared_package=groups[rid],atomic_requirement=r['atomic_requirement'],
        existing_candidate_methods='; '.join(sorted({a['method'] for a in relevant})),
        mapped_scopes='; '.join(sorted({a['coverage_scope'] for a in relevant})),
        remaining_shared_observation=notes[groups[rid]],
        gap_kind=gap_kind,current_status=r.get('producer_run_disposition') or 'NO_RUNTIME_CANDIDATE',
        latest_raw_methods='; '.join(sorted({b['method']+':'+b['execution_result']+'@'+b['run_prefix'] for b in raw})),
        limitation='Package prose is shared execution planning; the full atomic requirement remains the acceptance boundary. No PASS or Review status inferred.', **closure_plan(r)))
# Closure successor observations are a separate producer overlay. Preserve old
# route/current status and independent Review fields; do not turn partial raw
# PASS into full atomic acceptance or label old executions as fresh.
closure_path=ROOT/'STAGE9_CLOSURE_REMAINING_SOFTWARE.tsv'
closure={r['atomic_requirement_id']:r for r in read(closure_path.name)} if closure_path.exists() else {}
for row in out:
    item=closure.get(row['atomic_requirement_id'],{})
    row['closure_supplement_reference']='STAGE9_CLOSURE_REMAINING_SOFTWARE.tsv#'+row['atomic_requirement_id'] if item else ''
    row['closure_producer_predicate_state']=item.get('current_predicate_state','')
    row['closure_exact_passed_methods']=item.get('exact_new_passed_methods','')
    row['closure_work_kind']=item.get('work_kind','')
    row['prior_minimum_remaining_predicate']=row['minimum_remaining_predicate']
    if item and item['current_predicate_state']!='EXISTING_ATOMIC_ASSEMBLY_OR_NAMED_MISSING_OBSERVATION':
        row['minimum_remaining_predicate']=item['minimum_remaining_predicate']
        row['remaining_shared_observation']=item['minimum_remaining_predicate']
    if item.get('work_kind')=='NEW_RUNTIME_PREDICATE_ASSEMBLY_NO_REPEAT_REQUEST':
        row['fresh_runtime_needed']='no_repeat_of_newly_observed_predicate_pending_atomic_review'
with (ROOT/'STAGE9_CLOSEOUT_REMAINING_PREDICATES.tsv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=list(out[0]),delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(out)
software=[r for r in rows if r['category'] in ('B','C')]
print(json.dumps(dict(total=len(rows),software=len(software),direct_method_candidates=len({r['atomic_requirement_id'] for r in software}&direct),
    static_candidates_without_direct_method=len(({r['atomic_requirement_id'] for r in software}&static_direct)-direct),
    producer_pass_candidates=sum(r.get('producer_run_disposition')=='PRODUCER_PASS_CANDIDATE' for r in software),
    remaining_software_rows=len(out),remaining_gap_kinds=dict(collections.Counter(r['gap_kind'] for r in out)),remaining_shared_packages=dict(collections.Counter(r['shared_package'] for r in out)),closure_routes=dict(collections.Counter(r['closure_route'] for r in out)),minimal_action_groups=dict(collections.Counter(r['minimal_action_group'] for r in out)),
    external_gates=sum(r['category']=='D' for r in rows),historical_bound=sum(r['category']=='A' for r in rows),contract_na=sum(r['category']=='E' for r in rows),
    evidence_status='Current raw results are bound; producer candidates remain pending dependency compatibility and independent sufficiency review'),ensure_ascii=False,indent=2))
