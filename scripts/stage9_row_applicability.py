#!/usr/bin/env python3
"""Small, read-only-source row assembly for independent Stage 9 review.

No runtime/atomic PASS, Finding closure, new test run, image export or source copy.
Existing raw/source/image identities are referenced and checked, not repackaged.
"""
from pathlib import Path
import collections, csv, hashlib, json, re

ROOT = Path(__file__).resolve().parents[1]
RUN = Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001')
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def table(p): return list(csv.DictReader((ROOT/p).open(), delimiter='\t'))
remaining = table('STAGE9_CLOSEOUT_REMAINING_PREDICATES.tsv')
selected = [r for r in remaining if r['closure_route'].startswith('REVIEWED_') or r['closure_route'] in ('REVIEW_EXISTING_RUNTIME_FIRST', 'REVIEW_EXISTING_VISUAL_FIRST')]
assert len(selected) == 89 and len({r['atomic_requirement_id'] for r in selected}) == 89
catalog = {r['method']: r for r in table('STAGE9_CLOSEOUT_TEST_CATALOG.tsv')}
raw = table('STAGE9_CLOSEOUT_RUN_METHODS.tsv')
latest = {r['method']: r for r in raw if r['selected_latest_node'] == 'True'}
runs = {r['run_prefix']: r for r in table('STAGE9_CLOSEOUT_RUN_CATALOG.tsv')}
for run in runs.values():
    for key in ['raw_tests','summary','source_manifest']:
        assert sha(run[key])==run[key+'_sha256'], (run['run_prefix'],key)
static = json.loads((ROOT/'STAGE9_CLOSEOUT_STATIC_CANDIDATE.json').read_text())
static_rows = {r['atomic_requirement_id']: r for r in static['observations']}
review = ROOT/'STAGE9_CLOSEOUT_BATCH_REVIEW.md'
review_lines = review.read_text().splitlines()
static_start = next(i for i,l in enumerate(review_lines,1) if l.startswith('## 追加独立复审：36项静态候选'))
fixed = {n: ROOT/f'stage9_closeout_evidence/code-candidate-{n}' for n in ('017','019','020','023')}
manifests = {n: json.loads((p/'MANIFEST.json').read_text()) for n,p in fixed.items()}
for n, manifest in manifests.items():
    assert all(sha(fixed[n]/p)==digest for p,digest in manifest.items())
current_start = {p: sha(ROOT/p) if (ROOT/p).is_file() else None for p in manifests['023']}

# Additional actual methods were omitted from the old partial relation list.
# These references are assembly candidates, not changes to runtime disposition.
plans = {}
def plan(ids, established, gap, extra='', images='', dependencies='business'):
    for rid in ids.split():
        assert rid not in plans, rid
        plans[rid] = dict(established_predicate_candidate=established, still_missing_or_review_question=gap,
            additional_method_refs=extra.split(), image_selection=images, dependency_scope=dependencies)

plan('P21-020.a',
     'Current Settings wage/start/end change while Today snapshot/scheduled timestamps and settled amount remain frozen.',
     'The bound method does not assert visible “修改将于明日生效” or a subsequent natural-day clock-in using new rules. Source banner conditional and existing next-day tests must be joined; obtain only missing visible/native assertion in shared Settings session.',
     'testCompletedPreviousDayIsRetainedThenAtomicallyClearedByStartToday', dependencies='settings')
plan('P21-028.a UI18-008.a',
     'Seven-state presentation asserts earning status/live precision; formatter announces realtime estimate; 120% production render has exact earning target and no clipping.',
     'Confirm actual earning screenshot and source label establish “今日已获得/实时收入估算” prominence; no salary-rate copy inference from this alone.',
     'testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'earning', 'panel')
plan('P21-037.a',
     'Independent early/late clock-in arithmetic binds planned progress at time boundaries independently from wage earned; standard support presentation renders plan progress.',
     'Join actual 0/100 percent support text and source progress binding; model arithmetic alone does not establish visible percentage.',
     'testSevenBusinessStatesHaveDeterministicCopyPrecisionAndActions testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'clockedInWaiting earning awaitingClockOut', 'panel')
plan('P21-038.a P21-039.a',
     'Duration formatter explicitly maps 13,638,000ms to03:47:18; earning/waiting source branch and existing corresponding pictures identify countdown versus time-to-start.',
     'Formatter assertion alone is not live label binding; reviewer should inspect named earning/waiting pictures and support branch. Real background-return continuity is separately queued.',
     'testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'earning clockedInWaiting', 'panel')
plan('P21-043.a',
     'Completed presentation and actual completed production render use settled two-decimal amount, blessing and completed support fields.',
     'Review completed branch has no countdown producer, plus existing screenshot; static picture alone cannot prove absence of dynamic updates.',
     'testNativeOdometerCancelsForReduceMotionCalibrationAndSettlement testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'completed', 'panel')
plan('P21-049.a P22-018.a',
     'Old unfinished Today survives Store restore/refresh and rejects new clock-in; real process termination/recovery preserves timestamps and scheduled-end amount.',
     'Join old-date presentation and stopped-at-old-end clauses. Actual system sleep/wake remains separate environmental gate, not claimed from deterministic refresh.',
     'testEarningSurvivesRealProcessTerminationAndScheduledEndRecoveryStopsGrowth testOldWorkdaySurfacesDateAndStartTodayOnlyAfterCompletion testClockOutOnNextAndMultipleDaysIsCommittedAgainstFrozenTodaySnapshot', 'old-settlement', 'business')
plan('P21-050.a UI18-014.a',
     'Real files retain old completed Today until explicit start-today delete succeeds; native hosted confirmation cancellation retains old settlement; failure preserves old record.',
     'Review join of command preflight/deletion order and UI error receipt; only add visible delete-failure sample if existing screenshots/AX lack it.',
     'testStartTodayEveryPreflightFailurePreservesRecordsAndSuccessOrdersBeforeDelete', 'old-settlement', 'settings')
plan('P21-053.a UI18-016.a',
     'Damaged Settings preserves prior-day completed settlement, disables start-today with repair reason in Panel/Menu; missing reset leads UNCONFIGURED, valid replacement leaves Today priority intact.',
     'Review three-way Today matrix join, not blanket READY; no additional old-settlement rendering needed for the already-reviewed Day14/16 cases.',
     'testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testDamagedSettingsCommitSuccessPublishesOnceWithoutAnyPostCommitDerivationForAllTodayStates', 'damaged-old', 'settings')
plan('P21-054.a UI18-019.a UI18-020.a',
     'Hosted menu covers Settings-only/both-damaged/old-completed priority; hosted work-rules covers ordinary/damaged×Today3×conflict/I-O; file-backed double-damage confirms transitions/target-record-only changes.',
     'Missing+Today3 visual cross-surface completeness must be assembled explicitly. Native damaged-Settings method remains unexecuted in old bindings; do not treat Store/model combinations as full native flow.',
     'testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testHostedWorkRulesSavingAndFailureSurfacesPreserveAllSettingsTodayCombinations testRestorePublishesNoFakeStateBeforeLoadingAndThenUnconfigured testDamagedSettingsUseBlockingRecoveryUntilExplicitPlanBasedReplacement', 'damaged-old recoveryRequired', 'settings')
plan('P21-055.a P22-026.a T-039.a',
     'Store tests identify Today main error/Settings secondary and both reset orders; additional019 file-backed method checks bytes after cancel, Settings-first, Today-first and replace-first at every transition.',
     'No additional file-order test identified: previously omitted actual file method supplies missing persistence clause. Reviewer must verify error priority projection to relevant surface; no independent acceptance inferred.',
     'testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testHostedMenuRecoveryAndDamagedSettingsPreserveContractPriorityAndDisabledStartToday', 'recoveryRequired damaged-old', 'settings')
plan('P21-071.a',
     'Fake notification permission denial/schedule failure and cancellation diagnostics preserve authoritative completion; clock end and in-app state derive independently.',
     'Actual OS suppression/non-delivery is outside fake service evidence. Join current notification API closure and real system gate; do not request another equivalent spy test.',
     'testEarlyClockInAutoStopAndLateClockOutUseAllAuthoritativeStates testEarlyClockOutCancelsAndFailureNeverChangesCompletedBusinessState', dependencies='services')
plan('P21-080.non_color P21-098.non_color',
     'Seven-state presentation asserts distinct status/action/precision; A/B state render matrix retains text and semantic primary actions in both appearances.',
     'Review per-state icon/text in existing28 images and source branches; this does not close all non-text contrast or actual VoiceOver/focus gates.',
     'testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'all-states', 'panel')
plan('P21-087.a',
     'Real ZIP validation supplies light/dark preview; full required preview states render; install/reinstall/upgrade and failure-cleanup operate on temporary repository with preserved old files.',
     'Preview-before-install user confirmation/real chooser/drag remains in native lifecycle queue. Review safety corpus and hosted held-commit evidence rather than duplicate repository tests.',
     'testHostedImportCommitRejectsEscapeAndCancelUntilInstallationCompletes', dependencies='theme')
plan('P21-091.a',
     'Named lifecycle method asserts firstInstall/reinstall/upgrade disposition, one1.1.0 installed package after restart, downgrade/author-conflict codes; atomic replacement failure preserves old bytes.',
     'Actual reinstall cancel/confirm and conflict delete-before-reinstall instruction are native/documented-UI clauses, already queued; repository cases do not show those controls.',
     'testCancellationAndAtomicReplacementFailurePreserveBusinessAndOldTheme', dependencies='theme')
plan('P21-093.a',
     '019 complete earning Theme trajectory proves current deletion commits persistent A and keeps Business/notifications; prior deletion-failure test preserves valid current default.',
     'Non-current deletion leaving selected user Theme unchanged needs exact existing/native observation. Changed restore-default test cannot inherit019 method PASS; native delete selector is pending.',
     'testEarningThemeSwitchHeldUpgradeDeleteFallbackPreservesFullBusinessTrajectory', dependencies='theme')
plan('P21-095.a P22-049.a P22-058.a',
     'Startup revalidation reads actual corrupted/incompatible installed declarations, disables package, defaults A with notice and advances real BusinessStore earning to scheduled end while preserving record bytes; missing/mode cases have separate tests.',
     'Join actual composition-root startup routing with repository/ThemeStore re-creation evidence and valid fresh-process receipt; do not call repository re-creation a fresh application process. Native corrupted-theme launch only if reviewer cannot establish that composition join.',
     'testStartupRevalidatesActualManifestAndFallsBackWithoutTouchingBusinessRecords testPersistedUserThemeRestoresInFreshProcessesWithoutChangingBusinessOrNotifications testSystemAppearanceFallbackPersistsAOrReportsFailedSaveWithoutChangingBusiness', dependencies='theme')
plan('P21-110.a UI18-002.a T-062.a',
     'A/B profile/resource/token identity and28 production frame renders combine with byte-preserving Theme selection and full business/notification trajectory; carry test compares exact status/settings/hide/amount/support/action frame geometry.',
     'Review per-state hit regions and allowed Token/resource delta, not only overall size. Actual A/B focus order and system accessibility remain separately queued.',
     'testHostedAmountCarriesKeepOtherControlsFixedAndClockOutActionUsable testEarningThemeSwitchHeldUpgradeDeleteFallbackPreservesFullBusinessTrajectory testBundledThemesMatchApprovedNamesMetricsAndLightDarkTokenGroups', 'all-states carry', 'panel')
plan('P22-016.a UI18-041.business_retry',
     'Both DST errors across restore/refresh/cross-day/timezone-change fail with0writes/no fake state then retry with one new revision; ordinary/damaged save preconstructs target/event/intent and has0postcommit parser/deriver/reconcile.',
     'Business retry has direct reusable method set; source/helper identity and all required context consumers need reviewer join. Real startup->Settings clearance remains separate UI18-041.real_settings_flow.',
     'testScheduleErrorEntryMatrixPreservesRecordsAndSupportsFailedThenSuccessfulRetry testHeldSettingsSaveFreezesClockAndTimeZoneAcrossEveryContextConsumer', dependencies='business')
plan('P22-025.a T-017.a',
     'Every named preflight checkpoint helper loops ordinary/damaged×Today missing/valid/damaged; checks0repository/temp writes, unchanged tokens/revisions/bytes/ViewState; postcommit success/conflict/I-O methods and file-reset orders supply independent clauses.',
     'Review all helper assertions and damaged banner/input/UI revision preservation separately. Existing hosted transaction command is sent at Store, not by editing native field; actual UI clause cannot be inferred just from successful Business matrix.',
     'testEverySettingsPlanCheckpointFailsBeforeRepositoryForOrdinaryAndDamagedSave testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testDamagedSettingsPreviousSettlementRetainsRepairEntryAndCrossdayClockOutDates testHostedWorkRulesSavingAndFailureSurfacesPreserveAllSettingsTodayCombinations', 'damaged-old', 'settings')
plan('P22-054.a',
     'Validator corpus exercises unrecoverable low contrast, fallback text replacement and metric clamping; primary/status contrast matrices cover A/B states.',
     'Missing focus/pure-color/font-overflow clauses require source policy + actual frame/focus evidence; do not imply all accessibility rejection variants from low-contrast test alone.',
     'testPrimaryActionStatesMeetContrastForAAndBInLightAndDark testAllStatusVisualAndTextTokensMeetContrastWithDeterministicFallback testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'all-states', 'theme')
plan('P23-07.a',
     'Damaged persisted Settings/Today are retained through confirmed recovery and failed writes, no fake amount; hosted recovery/menu and old-settlement evidence show business priority.',
     'Native corrupted-data startup/no-white-window verification is currently only candidate; join actual later native result rather than infer it from typed repository response.',
     'testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testCorruptedTodayIsPreservedRequiresResetAndCannotBeOverwritten testHostedMenuRecoveryAndDamagedSettingsPreserveContractPriorityAndDisabledStartToday', 'recoveryRequired damaged-old', 'settings')
plan('P23-09.a',
     'Default A and distinct B resources, standard slots, full earning user-theme lifecycle/notifications, legacy0.5 install/select/restore and malicious archive corpus already have actual019 methods.',
     'Assemble these previously unmapped methods and actual images; explicit review of full Theme safety boundary still required, not a new Theme quantity target.',
     'testBundledCatalogValidatesAAndBWithStableReservedIDs testBStateAssetsCompileAndPanelRendersAAndBInLightAndDark testEarningThemeSwitchHeldUpgradeDeleteFallbackPreservesFullBusinessTrajectory testLegacy05PackageWithoutCapabilityFieldsInstallsSelectsAndRestores testPathLinkDuplicateAndExecutableCorpusIsRejectedWithoutStagingLeak', 'all-states', 'theme')
plan('T-019.a',
     'Real temporary RecordRepository tests prove atomic commit/migration/corruption, genuine process SIGKILL restore and oldToday start-today success/failure ordering.',
     'Add omitted real-process/file-order methods to reviewer assembly; no new broad persistence suite identified. Oldraw failures and unavailable waitpid status remain explicit.',
     'testEarningSurvivesRealProcessTerminationAndScheduledEndRecoveryStopsGrowth testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testAtomicReplacementFailureKeepsPreviousRecordAndLeavesNoTemporaryFile testStartTodayEveryPreflightFailurePreservesRecordsAndSuccessOrdersBeforeDelete', dependencies='business')
plan('T-060.a',
     'Historical Stage5 verified record is available; current Panel amount/geometry/render and native odometer cancellation methods provide narrower current facts.',
     'Actual current Settings/keyboard/ReduceMotion/VoiceOver gate still not closed by historical Stage5 record; require explicit system results where Contract demands them.',
     'testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances testNativeOdometerCancelsForReduceMotionCalibrationAndSettlement', 'all-states', 'panel')
plan('T-063.a',
     'Actual019 archive path/link/duplicate/executable, capacity/header, schema/media/hash, encryption/multivolume/compression/special-file corpus plus cleanup/held install tests are available.',
     'Final independent security sufficiency over complete import closure and current diagnostic delta remains review work; no broad new corpus solely to replace missing mapping.',
     'testPinnedZIPFoundationAndStrictSchemaAreAvailable testPathLinkDuplicateAndExecutableCorpusIsRejectedWithoutStagingLeak testTrailingArchivePayloadIsRejectedAndCleaned testCapacityBombCountAndActualDecodedHeaderDeceitCorpusIsRejected testManifestMediaHashMissingAndForbiddenContentCorpusIsRejected testEncryptedMultivolumeUnsupportedCompressionAndSpecialFileCorpusIsRejected testCancellationAndAtomicReplacementFailurePreserveBusinessAndOldTheme testHostedImportCommitRejectsEscapeAndCancelUntilInstallationCompletes', dependencies='theme')
plan('UI18-001.a UI18-003.panel_size',
     'Fixed standardProfile and constraint code never resize; actual28 A/B renders assert host fitting320x190 and carry source frames match safe-area layout.',
     'UI18-001 additionally requires1x+2x: actual images are2x; check existing1x evidence before acquiring only missing scale. UI18-003.panel_size does not itself demand new physical display.',
     'testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances testHostedAmountCarriesKeepOtherControlsFixedAndClockOutActionUsable', 'all-states carry', 'panel')
plan('UI18-003.business_state',
     'Actual record bytes remain identical after B/dark selection; additional019 complete earning Theme lifecycle compares full ViewState, Today, Settings, notification calls and record bytes with a no-Theme control.',
     'Reviewer should join B-specific byte test with complete trajectory/source Theme-to-Business isolation. No new equivalent Business spy test identified.',
     'testEarningThemeSwitchHeldUpgradeDeleteFallbackPreservesFullBusinessTrajectory', dependencies='theme')
plan('UI18-006.a',
     'Seven-state model asserts status/amount/action; actual A/B/light/dark28 images and020 exact native glyph targets show implemented standard layouts.',
     'Review each state icon/support/copy against UI§5; current model assertions omit some support/icon fields. Existing image audit can close visible clauses if exact, not picture count alone.',
     'testSevenBusinessStatesHaveDeterministicCopyPrecisionAndActions testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'all-states', 'panel')
plan('UI18-009.a',
     'Awaiting state model uses rounded2decimal amount and clock-out action; actual awaiting render has settled target and activeAnimationCount0.',
     'Review100percent and“请打卡下班”support text in source/picture; no extra odometer run needed for already-bound settled/no-animation clause.',
     'testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances testNativeOdometerCancelsForReduceMotionCalibrationAndSettlement', 'awaitingClockOut', 'panel')
plan('UI18-012.a',
     'Recovery model/render exposes no amount; actual file reset cancellation and two-step confirmations preserve/deletes exact damage tokens; hosted keyboard method targets recovery controls.',
     'Latest bound whole-page keyboard method is Failed; use parent later repaired native result before claiming actual two-confirmation action accessibility. Recovery picture alone not enough.',
     'testDamagedTodayRequiresConfirmedResetAndResetFailurePreservesRecovery testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances', 'recoveryRequired', 'settings')
plan('UI18-013.a',
     'Old incomplete Store restore keeps awaiting, blocks clock-in; old date presentation plus next/multiple-day frozen-snapshot settlement and existing old-settlement images supply result.',
     'Join same required old record/clock-out path, not unrelated image/model values. Actual sleep/wake gate is separate.',
     'testIncompletePreviousDayIsRetainedAndBlocksNewClockIn testClockOutOnNextAndMultipleDaysIsCommittedAgainstFrozenTodaySnapshot testPreviousWorkdayMountedSettlementKeepsDateAmountTimesBlessingAndCancel', 'old-settlement', 'settings')
plan('UI18-017.a',
     'Reviewer already closed S9C-004 with actual Day14/16 images/raw; fixed method asserts snapshot timezone date/time and max amount120percent; separate east/west timezone test preserves interpretation.',
     'Join named east/west method for whole atomic text; do not rerender previously independently inspected Day14/16 unchanged Panel.',
     'testTodaySnapshotTimezoneWinsAfterEastAndWestSystemTimezoneChanges testClockOutOnNextAndMultipleDaysIsCommittedAgainstFrozenTodaySnapshot', 'damaged-old', 'settings')
plan('UI18-018.a',
     'Both DST entry matrix variants publish no business ViewState/no writes; Panel/Menu source distinguishes schedule error and offers Settings recovery entry.',
     'No named hosted schedule-error no-character/progress/countdown full surface assertion in old map; real startup->Settings flow is already queued and should capture this same state once.',
     'testScheduleErrorEntryMatrixPreservesRecordsAndSupportsFailedThenSuccessfulRetry testRestorePublishesRecoverableGapErrorWithoutMutatingRecords testRestorePublishesRecoverableFoldError', dependencies='settings')
plan('UI18-021.a',
     'File-backed settings-first reset retains damagedToday exactly and keeps Recovery; ordinary validToday and noToday reset cases use Business matrix/source state projection.',
     'Need exact same-phase validToday snapshot preservation and noToday UNCONFIGURED clause from existing reset methods; native damaged selector awaiting current run. Never infer unconditional READY.',
     'testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders testExplicitSettingsRecoveryBacksUpDamageAndLeavesTodayAndThemeUnchanged', 'recoveryRequired', 'settings')
plan('UI18-022.a UI18-038.a UI18-039.a',
     'Held same-context save samples frozen clock/timezone;0postcommit recomputation; hosted WorkRules observes checking->saving->error across ordinary/damaged×Today3×conflict/I-O and suppresses success/announcement; success receipt observed only after durable commit.',
     'Hosted matrix initiates Store.send and does not itself verify edited draft retention/field focus/Panel/Menu pixels. Match input, UI revision, damaged banner and exact error text with production source and native shared/DST result; only missing visible clause needs observation.',
     'testEverySettingsPlanCheckpointFailsBeforeRepositoryForOrdinaryAndDamagedSave testDamagedSettingsCommitSuccessPublishesOnceWithoutAnyPostCommitDerivationForAllTodayStates testDamagedSettingsCommitConflictsAndIOFailuresPreserveAllThreeTodayStates', dependencies='settings')
plan('UI18-030.a',
     'Bundled A token groups/names/metrics and exhaustive status/primary button contrast resolve safe colors in light/dark; system mode complete group fallback is separately tested.',
     'Core Token values/contrast can be reviewed from current matching source/results; non-primary controls and actual system appearance matrix stay separate IDs.',
     'testUnsupportedAppearanceResolvesEntireDefaultGroupForExplicitAndSystemModes', 'all-states', 'theme')
plan('UI18-031.a UI18-032.a UI18-034.a',
     'B required assets compile, catalog validates declarations, decoration slot60x50/inset3/non-hit policy is asserted; production all-state pictures/carry frames and source clipped/hidden decoration establish narrow safe-slot evidence.',
     'Review conditional recovery/confirmation/loading branches and focus/error occlusion using existing six019 images/source. Geometry alone does not certify actual hit behavior/complete focus-ring visibility.',
     'testHostedAmountCarriesKeepOtherControlsFixedAndClockOutActionUsable testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances testMountedClockOutConfirmationRefreshesRetainsFailureAndCancelContinuesEarning', 'all-states confirmation carry', 'panel')
plan('UI18-033.a',
     'Accessibility policy disables decoration motion under ReduceMotion; standard B resource/decorative source is not driven by earned rate; native odometer reduced/calibration cancellation is separately bound.',
     'System ReduceMotion actual effect and companionFocus source path need explicit current review; policy bool or odometer cancellation does not alone prove every decorative animation stopped.',
     'testNativeOdometerCancelsForReduceMotionCalibrationAndSettlement', 'earning', 'panel')
plan('UI18-043.a',
     'Actual validator error is presented in hosted sheet; native AX confirms error and absence of install-confirm, Escape dismisses, selected A persists; failed use suppresses success.',
     'Generic validation error is existing reusable evidence; current required-version diagnostics use new repair results, real system chooser excluded. Do not broaden generic error to every new diagnostic.', dependencies='theme')
plan('UI18-046.a',
     'Hosted settings checking/saving/error, restore-held menu disabled/no business action, actual Theme empty/error dismissal, Theme success/failure toast and held noncancelable commit have distinct actual methods.',
     'Join complete source§16 state predicates and Theme fallback reason/presentation. No single method proves all states; only missing conditional-state rendering needs further sample.',
     'testSystemAppearanceFallbackPersistsAOrReportsFailedSaveWithoutChangingBusiness testHostedMenuRecoveryAndDamagedSettingsPreserveContractPriorityAndDisabledStartToday', 'recoveryRequired confirmation', 'settings')
plan('UI18-049.decorative_tree',
     'Carry hosted B checks actual AX identifier absent; old damaged-settlement has no decoration; production decoration is accessibilityHidden with disabled hit testing.',
     'Reviewer may combine source unconditional hidden modifier with actual earning AX traversal. Additional actual state observation only if condition-dependent decoration path bypasses modifier.',
     '', 'carry damaged-old', 'panel')

runtime_ids = {r['atomic_requirement_id'] for r in selected if not r['closure_route'].startswith('REVIEWED_')}
assert set(plans) == runtime_ids, (runtime_ids-set(plans),set(plans)-runtime_ids)

def method_fragment(path, name):
    lines=path.read_text().splitlines(keepends=True)
    hits=[i for i,l in enumerate(lines) if re.search(r'\bfunc\s+'+re.escape(name)+r'\(',l)]
    if len(hits)!=1:return None
    start=hits[0];end=start+1
    while end<len(lines) and not re.match(r'    }\s*$',lines[end]):end+=1
    assert end<len(lines)
    body=''.join(lines[start:end+1])
    assertions=[dict(line=i+1,text=l.rstrip()) for i,l in enumerate(lines[start:end+1],start) if 'XCTAssert' in l or 'XCTFail' in l or 'XCTUnwrap' in l]
    return dict(start_line=start+1,end_line=end+1,sha256=hashlib.sha256(body.encode()).hexdigest(),assertion_lines=assertions,body=body)

method_records={}
def reference_method(name):
    if name in method_records:return name
    assert name in catalog, name
    cat=catalog[name];actual=latest.get(name);rel=cat['test_file'];current=method_fragment(ROOT/rel,name)
    rec=dict(test_file=rel,current_file_sha256=sha(ROOT/rel),current_method_sha256=current['sha256'] if current else '',current_method_range=[current['start_line'],current['end_line']] if current else [])
    if actual:
        run=runs[actual['run_prefix']];source=Path(run['fixed_source'])/rel;frag=method_fragment(source,name)
        assert frag and frag['sha256']==actual['run_method_sha256'] and sha(source)==actual['run_source_file_sha256']
        rec.update(run_prefix=actual['run_prefix'],raw_result=actual['raw_result'],raw_node=actual['raw_node'],raw_node_url=actual['raw_node_url'],raw_tests=actual['raw_tests'],raw_tests_sha256=actual['raw_tests_sha256'],fixed_test_file=str(source),fixed_file_sha256=sha(source),fixed_method_sha256=frag['sha256'],fixed_method_range=[frag['start_line'],frag['end_line']],assertion_lines=frag['assertion_lines'],method_matches_current=bool(current and current['sha256']==frag['sha256']),whole_test_file_matches_current=sha(ROOT/rel)==sha(source),source_manifest=run['source_manifest'],source_manifest_sha256=run['source_manifest_sha256'],environment_reference='STAGE9_CLOSEOUT_RUN_CATALOG.tsv#'+actual['run_prefix'])
        # Named preservation helpers are material assertions, not an opaque test name.
        helpers=[]
        for helper in ['assertInjectedSaveSettingsPreflightFailure','assertScheduleSaveSettingsPreflightFailure','saveSettingsPreflightObservation','assertSaveSettingsPreflightPreserved','assertHeldSettingsConflictPreservesCompleteMatrix','settingsCommitFailureObservation','assertSettingsCommitFailurePreserved']:
            if helper in frag['body'] or (name.startswith('testSaveSettingsPreflight') and helper in ['saveSettingsPreflightObservation','assertSaveSettingsPreflightPreserved']):
                h=method_fragment(source,helper)
                if h:helpers.append(dict(name=helper,range=[h['start_line'],h['end_line']],sha256=h['sha256'],assertion_lines=h['assertion_lines']))
        rec['material_helper_fragments']=helpers
    else:
        rec.update(raw_result='NO_BOUND_EXECUTION',run_prefix='',assertion_lines=current['assertion_lines'] if current else [],method_matches_current=False,whole_test_file_matches_current=False,material_helper_fragments=[])
    method_records[name]=rec
    return name

# Existing images are referenced only; no copies or exports. Reviewed state comes
# from the actual independent report, not image existence or a green method.
image_records={}
six019={'06205E63-4C07-470C-A571-D271A25BB299.png','3BDC294B-4524-4F2B-BFA4-F44782DAA442.png','9C91966A-8AC2-4BDB-8865-225158073344.png','B8670644-F47F-4784-8B9D-F969C5A16E9C.png','3E0267AB-F08F-4502-9A91-3BAF0457BC28.png','B968E772-956A-4BF2-9C19-0CF4E0B6A709.png'}
for directory, source_candidate in [('Renders017Selected','017'),('Renders019','019')]:
    manifest=RUN/directory/'manifest.json'
    for test in json.loads(manifest.read_text()):
        for attachment in test['attachments']:
            filename=attachment['exportedFileName'];label=attachment.get('suggestedHumanReadableName','')
            if not filename.endswith('.png'):continue
            if directory=='Renders019' and filename not in six019 and not label.startswith('Stage9-Carry-'):continue
            path=RUN/directory/filename;assert path.is_file()
            key=directory+'/'+filename
            reviewed=directory=='Renders017Selected' or filename in six019
            image_records[key]=dict(path=str(path),sha256=sha(path),manifest=str(manifest),manifest_sha256=sha(manifest),test_identifier=test['testIdentifier'],test_identifier_url=test['testIdentifierURL'],label=label,source_candidate=source_candidate,source_manifest=str(fixed[source_candidate]/'MANIFEST.json'),source_manifest_sha256=sha(fixed[source_candidate]/'MANIFEST.json'),independent_visual_scope='Previously inspected according to019/020 review; 017 failed assertions retained' if directory=='Renders017Selected' else 'One of six specifically inspected019 images' if filename in six019 else 'Available019 carry image, not among six reviewer-inspected images',independently_reviewed=reviewed,producer_raw_scope='017 selected render method Failed despite available images' if source_candidate=='017' else '019 named method result from bound raw',review_reference=str(review),review_sha256=sha(review))
assert sum(k.startswith('Renders017Selected/') for k in image_records)==28
assert sum(Path(k).name in six019 for k in image_records)==6

def select_images(selection):
    if not selection:return []
    keys=[]
    for key,im in image_records.items():
        label=im['label'];match=False
        for tag in selection.split():
            if tag=='all-states' and key.startswith('Renders017Selected/'):match=True
            elif tag=='damaged-old' and 'DamagedSettings-PreviousSettlement' in label:match=True
            elif tag=='old-settlement' and ('PreviousSettlement' in label or 'PreviousWorkday' in label or 'Previous-Settlement' in label):match=True
            elif tag=='confirmation' and any(s in label.lower() for s in ['confirm','saving','failure']):match=True
            elif tag=='carry' and label.startswith('Stage9-Carry-'):match=True
            elif tag not in ['all-states','damaged-old','old-settlement','confirmation','carry'] and ('Text120-'+tag+'-') in label:match=True
        if match:keys.append(key)
    return keys

# Conservative named production/helper supersets, kept separate from a proven
# dynamic dependency graph. All identities are deduplicated once per old input.
base=[p for p in manifests['019'] if p.startswith(('IncomeClock/Domain/','IncomeClock/Infrastructure/Persistence/'))]
base += ['IncomeClock/Application/BusinessStore.swift','IncomeClock/Application/BusinessStoreModels.swift','IncomeClock/Application/BusinessWorkdayCalendar.swift']
groups={
 'business':base,
 'services':base+[p for p in manifests['019'] if p.startswith(('IncomeClock/Infrastructure/Notifications/','IncomeClock/Infrastructure/LoginItem/'))]+['IncomeClock/Application/Stage6ServiceModels.swift','IncomeClock/Application/LoginItemController.swift'],
 'theme':base+[p for p in manifests['019'] if p.startswith(('IncomeClock/Infrastructure/Theme/','IncomeClock/Resources/BuiltinThemes/'))]+['IncomeClock/Application/ThemeStore.swift','IncomeClock/Application/ThemeModels.swift','IncomeClock/Application/ThemeImportModels.swift'],
}
groups['panel']=groups['theme']+[p for p in manifests['019'] if p.startswith(('IncomeClock/Presentation/Panel/','IncomeClock/Resources/Assets.xcassets/')) and not p.endswith('EmptyPanelView 2.swift')]
groups['settings']=groups['panel']+['IncomeClock/Presentation/Settings/EmptySettingsView.swift','IncomeClock/Presentation/MenuBar/MenuBarContentView.swift']
common=['IncomeClock/App/AppDelegate.swift','IncomeClock/App/AppEnvironment.swift','IncomeClock/App/IncomeClockApp.swift','IncomeClock.xcodeproj/project.pbxproj','IncomeClock.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved','IncomeClock.xcodeproj/xcshareddata/xcschemes/IncomeClock.xcscheme','IncomeClockApplicationTests/ApplicationTestSupport.swift','IncomeClockDomainTests/DomainTestFixtures.swift','IncomeClockPersistenceTests/PersistenceTestSupport.swift']
dependency_records={}
def deps(scope):
    if scope in dependency_records:return scope
    entries=[]
    for rel in sorted(set(groups[scope]+common)):
        current=sha(ROOT/rel) if (ROOT/rel).is_file() else None
        entries.append(dict(path=rel,fixed019_sha256=manifests['019'][rel],fixed020_sha256=manifests['020'][rel],current_sha256=current,matches019=current==manifests['019'][rel],matches020=current==manifests['020'][rel]))
    dependency_records[scope]=dict(kind='Conservative manually declared source/helper/resource/config superset, not proof of runtime call graph',files=entries,current_changed_from019=[r['path'] for r in entries if not r['matches019']],compatibility_limit='019/020 reviewer accepted earlier AppDelegate canonical-root delta narrowly. Later current source/helper changes require exact bounded review; hash equality alone does not settle system/build-flag applicability.')
    return scope

# Exact frozen production fragments help the reviewer join a model assertion to
# the actual branch without treating a whole-file keyword search as proof.
source_fragments={}
for key,rel,start,end in [
    ('panel-state-presentation','IncomeClock/Presentation/Panel/EmptyPanelView.swift',163,241),
    ('panel-native-decoration','IncomeClock/Presentation/Panel/EmptyPanelView.swift',1420,1455),
    ('panel-error-priority','IncomeClock/Presentation/Panel/EmptyPanelView.swift',1530,1620),
    ('panel-native-progress-support','IncomeClock/Presentation/Panel/EmptyPanelView.swift',1630,1680),
    ('settings-draft-context-feedback','IncomeClock/Presentation/Settings/EmptySettingsView.swift',725,909),
]:
    path=fixed['019']/rel;lines=path.read_text().splitlines(keepends=True)
    fragment=''.join(lines[start-1:end])
    source_fragments[key]=dict(fixed_file=str(path),fixed_file_sha256=sha(path),lines=[start,end],fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),current_file=rel,current_file_sha256=sha(ROOT/rel),whole_file_matches019=sha(ROOT/rel)==sha(path),purpose='Exact source branch for reviewer predicate join; not additional runtime evidence')

row_records=[]
for r in selected:
    rid=r['atomic_requirement_id'];item=dict(atomic_requirement_id=rid,atomic_requirement=r['atomic_requirement'],route=r['closure_route'],independent_adjudication='PENDING; no PASS/CLOSED assigned by this producer')
    if rid in plans:
        p=plans[rid];names=set(filter(None,r['existing_candidate_methods'].split('; ')))|set(p['additional_method_refs'])
        if rid in ['P22-025.a','T-017.a']:
            names |= {n for n in catalog if n.startswith('testSaveSettingsPreflight')}
        item.update(**p,method_refs=[reference_method(n) for n in sorted(names)],image_refs=select_images(p['image_selection']),dependency_reference=deps(p['dependency_scope']))
        item['production_fragment_refs'] = list(source_fragments) if p['dependency_scope']=='settings' else [k for k in source_fragments if k.startswith('panel-')] if p['dependency_scope']=='panel' else []
        item['not_currently_passed_method_refs']=[n for n in item['method_refs'] if method_records[n]['raw_result']!='Passed' or not method_records[n]['method_matches_current']]
    else:
        observation=static_rows[rid]
        lines=[i for i,line in enumerate(review_lines,1) if i>=static_start and rid in line]
        assert lines,rid
        source_rows=[]
        for ref in observation['source_bindings'].split('; '):
            path,digest=ref.rsplit('#',1);q=Path(path) if Path(path).is_absolute() else ROOT/path
            source_rows.append(dict(path=path,recorded_sha256=digest,current_sha256=sha(q) if q.is_file() else None))
        item.update(review_reference=str(review),review_sha256=sha(review),review_lines=lines,review_text=[review_lines[i-1] for i in lines],established_predicate_candidate=r['reviewed_scope'],still_missing_or_review_question=r['minimum_remaining_predicate'],static_candidate_reference='STAGE9_CLOSEOUT_STATIC_CANDIDATE.json#'+rid,static_candidate_sha256=sha(ROOT/'STAGE9_CLOSEOUT_STATIC_CANDIDATE.json'),source_binding_count=len(source_rows),changed_source_bindings=[x for x in source_rows if x['recorded_sha256']!=x['current_sha256']],source_bindings_reference='STAGE9_CLOSEOUT_STATIC_CANDIDATE.json.observations['+rid+'].source_bindings',method_refs=[],image_refs=[])
    row_records.append(item)

assert len(row_records)==89 and len(plans)==62
for n,manifest in manifests.items():
    assert all(sha(fixed[n]/p)==digest for p,digest in manifest.items())
inputs=['STAGE9_CLOSEOUT_REMAINING_PREDICATES.tsv','STAGE9_CLOSEOUT_RUN_CATALOG.tsv','STAGE9_CLOSEOUT_RUN_METHODS.tsv','STAGE9_CLOSEOUT_TEST_CATALOG.tsv','STAGE9_CLOSEOUT_STATIC_CANDIDATE.json','STAGE9_CLOSEOUT_BATCH_REVIEW.md']
current_end = {p: sha(ROOT/p) if (ROOT/p).is_file() else None for p in manifests['023']}
current_drift = [p for p in current_start if current_start[p]!=current_end[p]]
assert not current_drift, ('Current workspace changed during assembly; rerun after active edits settle',current_drift)
result=dict(classification='DEVELOPER_ROW_EVIDENCE_APPLICABILITY_FOR_INDEPENDENT_REVIEW',source_policy='References only; no raw/source/image copies or new executions; exact old failures retained',producer='python3 scripts/stage9_row_applicability.py',producer_sha256=sha(__file__),input_sha256={p:sha(ROOT/p) for p in inputs},current_workspace_changed_during_read=current_drift,current_validation_source=dict(path='STAGE9_VALIDATION_SOURCE.json',sha256=sha(ROOT/'STAGE9_VALIDATION_SOURCE.json')) if (ROOT/'STAGE9_VALIDATION_SOURCE.json').exists() else None,rows=row_records,methods=method_records,dependency_scopes=dependency_records,production_source_fragments=source_fragments,images=image_records,summary=dict(rows=len(row_records),runtime_or_visual_rows=len(plans),reviewed_static_governance_history_rows=len(row_records)-len(plans),unique_methods=len(method_records),referenced_images=len(image_records),independently_reviewed_images=sum(im['independently_reviewed'] for im in image_records.values()),raw_results=dict(collections.Counter(m['raw_result'] for m in method_records.values())),current_method_mismatch=sum(not m['method_matches_current'] for m in method_records.values())),limitations=['No independent atomic sufficiency/compatibility conclusion is manufactured.','All methods refer to the already-bound run inventory; later S9C006/007 passing selectors await stable exact source/run binding.','Old full test-file or production/helper/config differences are explicit review work even when method body matches.','Source graph and image existence do not prove native gestures, real OS state or production Release behavior.','27 independent static/history conclusions keep their exact reviewed scope and fixed023 origin; mutable active governance must be reread.'])
output=ROOT/'STAGE9_CLOSEOUT_ROW_APPLICABILITY.json'
output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(dict(**result['summary'],output_bytes=output.stat().st_size),ensure_ascii=False,indent=2))
