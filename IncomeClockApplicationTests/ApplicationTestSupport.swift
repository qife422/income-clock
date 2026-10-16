import Foundation
import AppKit
import Darwin
import XCTest
@testable import IncomeClock

enum ApplicationTestSupport {

    /// Sole declared Stage9 run; each named fixture directory is created once.
    /// No fallback temp root, overwrite, retry suffix or cleanup is permitted.
    static func makeResume008FixtureRoot(name: String, reservedGrowthBytes: Int,
                                         familyName: String = "Resume008BoundedFixtures") throws -> URL {
        let originalAllowed: Set<String> = [
            "wav-accepted", "unsupported-mp3-extension", "invalid-wav",
            "sound-exact-10MiB", "sound-over-10MiB-one-byte",
            "sound-exact-30-seconds", "sound-over-30-seconds-one-frame",
            "dimension-exact-4096", "dimension-over-4096",
            "pixels-exact-16000000", "pixels-over-16000000",
            "unicode-nfc-nfd", "unicode-width-fold", "unicode-diacritic-fold",
            "primary-100", "primary-120",
            "sound-full-decode-fixtures", "sound-full-decode-valid", "sound-full-decode-corrupt",
            "sound-recheck-10MiB", "sound-recheck-over-10MiB", "sound-recheck-30s", "sound-recheck-over-30s",
            "sound-recheck-wav", "sound-recheck-mp3", "sound-recheck-invalid-wav"
        ]
        let allowed: Set<String>
        let familyLimitBytes: Int64
        let perRootReserveLimit: Int
        switch familyName {
        case "Resume008BoundedFixtures":
            allowed = originalAllowed
            familyLimitBytes = 48 * 1_024 * 1_024
            perRootReserveLimit = 34 * 1_024 * 1_024
        case "Resume009PrimaryFixtures":
            allowed = ["primary-100", "primary-120"]
            familyLimitBytes = 2 * 1_024 * 1_024
            perRootReserveLimit = 1_024 * 1_024
        default:
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard allowed.contains(name), reservedGrowthBytes > 0,
              reservedGrowthBytes <= perRootReserveLimit else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let declaredRun = URL(fileURLWithPath:
            "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData", isDirectory: true)
        let values = try declaredRun.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Foundation may canonicalize /private/tmp to /tmp. Normalize the trusted
        // base once; aliases of that base are not descendant escapes.
        let run = declaredRun.resolvingSymlinksInPath().standardizedFileURL
        let allowedRunPaths: Set<String> = [
            "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData",
            "/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData"
        ]
        guard values.isDirectory == true, values.isSymbolicLink != true,
              allowedRunPaths.contains(run.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let family = run.appendingPathComponent(familyName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: family.path) {
            guard mkdir(family.path, 0o700) == 0 else { throw POSIXError(.EEXIST) }
        }
        let familyValues = try family.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard familyValues.isDirectory == true, familyValues.isSymbolicLink != true,
              family.resolvingSymlinksInPath().standardizedFileURL == family.standardizedFileURL,
              family.deletingLastPathComponent().standardizedFileURL == run else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Existing contents are accounted for; new unknown names or symlinks stop
        // the run. This read-only scan never follows links or leaves the family.
        let children = try FileManager.default.contentsOfDirectory(at: family,
            includingPropertiesForKeys: nil)
        guard children.count < allowed.count,
              children.allSatisfy({ allowed.contains($0.lastPathComponent) }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var pending = [family], count = 0, allocated: Int64 = 0, logical: Int64 = 0
        while let item = pending.popLast() {
            count += 1
            guard count <= 256 else { throw CocoaError(.fileWriteOutOfSpace) }
            let attributes = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_blocks >= 0 else { throw POSIXError(.EIO) }
            allocated += Int64(info.st_blocks) * 512
            logical += max(0, Int64(info.st_size))
            if attributes.isDirectory == true {
                pending += try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            }
        }
        // Preserve original-family accounting; the new tiny family additionally
        // bounds logical bytes and reserves its newly created directory slot.
        let accountedBytes = familyName == "Resume009PrimaryFixtures" ? max(allocated, logical) : allocated
        guard familyName != "Resume009PrimaryFixtures" || count < 256,
              accountedBytes + Int64(reservedGrowthBytes) <= familyLimitBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let root = family.appendingPathComponent(name, isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw POSIXError(.EEXIST) }
        guard root.deletingLastPathComponent().standardizedFileURL == family.standardizedFileURL,
              root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return root
    }

    static let timeZoneIdentifier = "Asia/Shanghai"

    static func timestamp(
        year: Int = 2026,
        month: Int = 8,
        day: Int = 13,
        hour: Int,
        minute: Int = 0
    ) -> TimestampMilliseconds {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: timeZoneIdentifier)!
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
        return TimestampMilliseconds(
            rawValue: Int64((date.timeIntervalSince1970 * 1_000).rounded())
        )
    }

    static func proposedSettings(
        wageCents: Int64 = 30_000,
        startMinuteOfDay: Int = 9 * 60,
        endMinuteOfDay: Int = 18 * 60,
        notificationsEnabled: Bool = false,
        alwaysOnTop: Bool = true,
        lockPanelPosition: Bool = false,
        hideInFullScreen: Bool = true,
        launchAtLogin: Bool = false,
        panelVisible: Bool = true,
        panelPlacement: PanelPlacementRecord? = nil,
        updatedAtMs: Int64 = 0
    ) -> SettingsRecord {
        SettingsRecord(
            schemaVersion: SettingsRecord.currentSchemaVersion,
            revision: .proposed,
            dailyWageCents: wageCents,
            workStartMinuteOfDay: startMinuteOfDay,
            workEndMinuteOfDay: endMinuteOfDay,
            notificationsEnabled: notificationsEnabled,
            alwaysOnTop: alwaysOnTop,
            lockPanelPosition: lockPanelPosition,
            hideInFullScreen: hideInFullScreen,
            launchAtLogin: launchAtLogin,
            panelVisible: panelVisible,
            panelPlacement: panelPlacement,
            updatedAtMs: updatedAtMs
        )
    }

    static func committedSettings(wageCents: Int64 = 30_000) -> SettingsRecord {
        proposedSettings(wageCents: wageCents).replacingRevision(.init(rawValue: 1))
    }

    static func workRules(
        wageCents: Int64 = 30_000,
        startMinuteOfDay: Int = 9 * 60,
        endMinuteOfDay: Int = 18 * 60
    ) -> WorkRuleSettingsInput {
        WorkRuleSettingsInput(
            dailyWageCents: wageCents,
            workStartMinuteOfDay: startMinuteOfDay,
            workEndMinuteOfDay: endMinuteOfDay
        )
    }

    static func timestamp(
        timeZoneIdentifier: String,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> TimestampMilliseconds {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: timeZoneIdentifier)!
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
        return TimestampMilliseconds(
            rawValue: Int64((date.timeIntervalSince1970 * 1_000).rounded())
        )
    }

    static func makeTemporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClockApplicationTests", isDirectory: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(root.path.contains("Application Support"))
        return root
    }
}

final class MutableTestClock: NowProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimestampMilliseconds
    private var samples = 0

    init(_ instant: TimestampMilliseconds) {
        self.instant = instant
    }

    func nowMilliseconds() -> TimestampMilliseconds {
        lock.withLock {
            samples += 1
            return instant
        }
    }

    func set(_ instant: TimestampMilliseconds) {
        lock.withLock { self.instant = instant }
    }

    func resetSampleCount() {
        lock.withLock { samples = 0 }
    }

    var sampleCount: Int {
        lock.withLock { samples }
    }
}

final class MutableTestTimeZoneIdentifierProvider: TimeZoneIdentifierProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String
    private var samples = 0

    init(_ identifier: String) {
        self.identifier = identifier
    }

    func currentIdentifier() -> String {
        lock.withLock {
            samples += 1
            return identifier
        }
    }

    func set(_ identifier: String) {
        lock.withLock { self.identifier = identifier }
    }

    func resetSampleCount() {
        lock.withLock { samples = 0 }
    }

    var sampleCount: Int {
        lock.withLock { samples }
    }
}

final class CountingScheduleResolver: LocalScheduleResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let delegate = LocalScheduleResolver()
    private let allowedCalls: Int
    private var calls = 0

    init(allowedCalls: Int) {
        self.allowedCalls = allowedCalls
    }

    func resolve(
        dateKey: WorkdayKey,
        timeZoneIdentifier: String,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) throws -> WorkdaySchedule {
        let invocation = lock.withLock {
            calls += 1
            return calls
        }
        guard invocation <= allowedCalls else {
            throw BusinessCalendarError.inconsistentSchedule
        }
        return try delegate.resolve(
            dateKey: dateKey,
            timeZoneIdentifier: timeZoneIdentifier,
            startMinuteOfDay: startMinuteOfDay,
            endMinuteOfDay: endMinuteOfDay
        )
    }

    var callCount: Int { lock.withLock { calls } }
}

struct FailingSaveSettingsPlanFaultInjector: SaveSettingsPlanFaultInjecting {
    let failingCheckpoint: SaveSettingsPlanCheckpoint

    func checkpoint(_ checkpoint: SaveSettingsPlanCheckpoint) throws {
        if checkpoint == failingCheckpoint {
            throw BusinessFailure.invalidCalendar
        }
    }
}

struct SaveSettingsExecutionObservation: Equatable {
    let preCommitStateDerivationCount: Int
    let preCommitEarningsCalculationCount: Int
    let preCommitViewStateConstructionCount: Int
    let postCommitStateDerivationCount: Int
    let postCommitEarningsCalculationCount: Int
    let postCommitViewStateConstructionCount: Int
    let successPublicationCount: Int
    let prematureSuccessPublicationCount: Int
}

final class FailOnPostCommitSaveSettingsExecutionObserver:
    SaveSettingsExecutionObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var repositoryCommitSucceeded = false
    private var preCommitCounts: [SaveSettingsDerivedOperation: Int] = [:]
    private var postCommitCounts: [SaveSettingsDerivedOperation: Int] = [:]
    private var successPublications = 0
    private var prematureSuccessPublications = 0
    private var parsingAfterCommit = 0
    private var reconcileAfterCommit = 0
    var postCommitParsingCount: Int { lock.withLock { parsingAfterCommit } }
    var postCommitReconcileCount: Int { lock.withLock { reconcileAfterCommit } }
    func willParseSettings() {
        let after = lock.withLock { () -> Bool in
            if repositoryCommitSucceeded { parsingAfterCommit += 1; return true }
            return false
        }
        if after { XCTFail("Forbidden post-commit Settings/Today snapshot parsing") }
    }
    func willReconcile() {
        let after = lock.withLock { () -> Bool in
            if repositoryCommitSucceeded { reconcileAfterCommit += 1; return true }
            return false
        }
        if after { XCTFail("Forbidden post-commit BusinessStore reconcile") }
    }

    func markRepositoryCommitSucceeded() {
        lock.withLock { repositoryCommitSucceeded = true }
    }

    func willInvokeDerivedOperation(_ operation: SaveSettingsDerivedOperation) {
        let invokedAfterCommit = lock.withLock {
            if repositoryCommitSucceeded {
                postCommitCounts[operation, default: 0] += 1
                return true
            }
            preCommitCounts[operation, default: 0] += 1
            return false
        }
        if invokedAfterCommit {
            XCTFail("Forbidden post-commit SaveSettings derived operation: \(operation)")
        }
    }

    func didPublishSuccess() {
        let publishedBeforeCommit = lock.withLock {
            successPublications += 1
            if !repositoryCommitSucceeded {
                prematureSuccessPublications += 1
                return true
            }
            return false
        }
        if publishedBeforeCommit {
            XCTFail("SaveSettings success was published before repository commit succeeded")
        }
    }

    var observation: SaveSettingsExecutionObservation {
        lock.withLock {
            SaveSettingsExecutionObservation(
                preCommitStateDerivationCount: preCommitCounts[.stateDerivation, default: 0],
                preCommitEarningsCalculationCount: preCommitCounts[.earningsCalculation, default: 0],
                preCommitViewStateConstructionCount:
                    preCommitCounts[.businessViewStateConstruction, default: 0],
                postCommitStateDerivationCount: postCommitCounts[.stateDerivation, default: 0],
                postCommitEarningsCalculationCount: postCommitCounts[.earningsCalculation, default: 0],
                postCommitViewStateConstructionCount:
                    postCommitCounts[.businessViewStateConstruction, default: 0],
                successPublicationCount: successPublications,
                prematureSuccessPublicationCount: prematureSuccessPublications
            )
        }
    }
}

struct SaveSettingsContextObservation: Equatable {
    let consumer: SaveSettingsContextConsumer
    let context: BusinessCommandContext
}

final class CapturingSaveSettingsCommandContextObserver:
    SaveSettingsCommandContextObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var captured: [SaveSettingsContextObservation] = []

    func observe(_ context: BusinessCommandContext, consumer: SaveSettingsContextConsumer) {
        lock.withLock {
            captured.append(.init(consumer: consumer, context: context))
        }
    }

    var observations: [SaveSettingsContextObservation] {
        lock.withLock { captured }
    }
}

@MainActor
final class HoldingSaveSettingsResultDeliveryController:
    SaveSettingsResultDeliveryControlling
{
    private(set) var deliveredKinds: [SaveSettingsResultDeliveryKind] = []
    private(set) var heldDelivery: SaveSettingsResultDelivery?
    private var shouldHoldNext = false

    func holdNext() {
        precondition(heldDelivery == nil)
        shouldHoldNext = true
    }

    func deliver(_ delivery: SaveSettingsResultDelivery) {
        deliveredKinds.append(delivery.kind)
        if shouldHoldNext {
            shouldHoldNext = false
            precondition(heldDelivery == nil)
            heldDelivery = delivery
        } else {
            delivery.deliver()
        }
    }

    func releaseHeld() {
        guard let delivery = heldDelivery else {
            XCTFail("Expected a held SaveSettings result delivery")
            return
        }
        heldDelivery = nil
        delivery.deliver()
    }
}

final class FailNextSaveSettingsPlanFaultInjector:
    SaveSettingsPlanFaultInjecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let failingCheckpoint: SaveSettingsPlanCheckpoint
    private var hasFailed = false

    init(failingCheckpoint: SaveSettingsPlanCheckpoint) {
        self.failingCheckpoint = failingCheckpoint
    }

    func checkpoint(_ checkpoint: SaveSettingsPlanCheckpoint) throws {
        let shouldFail = lock.withLock {
            guard checkpoint == failingCheckpoint, !hasFailed else { return false }
            hasFailed = true
            return true
        }
        if shouldFail {
            throw BusinessFailure.invalidCalendar
        }
    }
}

actor BusinessRecordRepositorySpy: BusinessRecordRepository {
    private var settings: SettingsRecord?
    private var today: TodayRecord?
    private var settingsDamage: DamagedRecordResult?
    private var settingsDamageToken = SettingsRecordToken.damaged(Data([0x44]))
    private var todayDamage: DamagedRecordResult?
    private var todayDamageToken = TodayRecordToken.damaged(Data([0x54]))

    private var settingsSaveErrors: [PersistenceError] = []
    private var settingsReplacementOnNextSaveFailure: SettingsRecord?
    private var shouldHoldNextBusinessSettingsLoad = false
    private var heldBusinessSettingsLoad: CheckedContinuation<Void, Never>?
    private var shouldHoldNextSettingsSave = false
    private var isHoldingSettingsSave = false
    private var heldSettingsSaveContinuation: CheckedContinuation<Void, Never>?
    private var nextTodaySaveError: PersistenceError?
    private var nextResetError: PersistenceError?
    private var shouldHoldNextTodaySave = false
    private var heldTodaySaveContinuation: CheckedContinuation<Void, Never>?
    private var startTodayCommitObserver: (@Sendable () -> Void)?
    private var settingsCommitSuccessObserver: (@Sendable () -> Void)?

    private(set) var settingsLoadCount = 0
    private(set) var todayLoadCount = 0
    private(set) var settingsSaveCount = 0
    private(set) var settingsSuccessfulWriteCount = 0
    private(set) var settingsTemporaryWriteCount = 0
    private(set) var settingsExternalWriteCount = 0
    private(set) var todaySaveCount = 0
    private(set) var resetTodayCount = 0

    init(
        settings: RecordLoadResult<SettingsRecord> = .missing,
        today: RecordLoadResult<TodayRecord> = .missing
    ) {
        switch settings {
        case .missing:
            break
        case let .loaded(record, _):
            self.settings = record
        case let .damaged(damage):
            settingsDamage = damage
        }
        switch today {
        case .missing:
            break
        case let .loaded(record, _):
            self.today = record
        case let .damaged(damage):
            todayDamage = damage
        }
    }

    func loadSettings() -> RecordLoadResult<SettingsRecord> {
        if let settingsDamage { return .damaged(settingsDamage) }
        guard let settings else { return .missing }
        return .loaded(settings, migration: .current)
    }

    func holdNextBusinessSettingsLoad() { shouldHoldNextBusinessSettingsLoad = true }
    func resumeBusinessSettingsLoad() {
        heldBusinessSettingsLoad?.resume()
        heldBusinessSettingsLoad = nil
    }
    func waitUntilBusinessSettingsLoadHeld() async {
        while heldBusinessSettingsLoad == nil { await Task.yield() }
    }
    func loadSettingsForBusiness() async -> SettingsTypedLoadResult {
        if shouldHoldNextBusinessSettingsLoad {
            shouldHoldNextBusinessSettingsLoad = false
            await withCheckedContinuation { heldBusinessSettingsLoad = $0 }
        }
        settingsLoadCount += 1
        if let settingsDamage { return .damaged(settingsDamage, token: settingsDamageToken) }
        guard let settings else { return .missing(.missing) }
        return .loaded(settings, token: .loaded(settings.revision))
    }

    func loadToday() -> RecordLoadResult<TodayRecord> {
        if let todayDamage { return .damaged(todayDamage) }
        guard let today else { return .missing }
        return .loaded(today, migration: .current)
    }

    func loadTodayForBusiness() -> TodayTypedLoadResult {
        todayLoadCount += 1
        if let todayDamage { return .damaged(todayDamage, token: todayDamageToken) }
        guard let today else { return .missing(.missing) }
        return .loaded(today, token: .loaded(today.revision))
    }

    func resetBusinessLoadCountsForValidation() {
        settingsLoadCount = 0
        todayLoadCount = 0
    }

    func saveSettings(
        _ proposed: SettingsRecord,
        expectedRevision: RecordRevision?
    ) async throws -> SettingsRecord {
        settingsSaveCount += 1
        if shouldHoldNextSettingsSave {
            shouldHoldNextSettingsSave = false
            isHoldingSettingsSave = true
            await withCheckedContinuation { continuation in
                heldSettingsSaveContinuation = continuation
            }
            isHoldingSettingsSave = false
        }
        if !settingsSaveErrors.isEmpty {
            let error = settingsSaveErrors.removeFirst()
            if let replacement = settingsReplacementOnNextSaveFailure {
                settings = replacement
                settingsReplacementOnNextSaveFailure = nil
            }
            throw error
        }
        if settingsDamage != nil {
            throw PersistenceError.damagedRecordRequiresRecovery(.settings)
        }
        let actual = settings?.revision
        guard expectedRevision == actual else {
            throw PersistenceError.revisionConflict(expected: expectedRevision, actual: actual)
        }
        let committed = proposed.replacingRevision(try (actual ?? .proposed).next())
        do {
            try committed.validated()
        } catch {
            throw PersistenceError.invalidProposedRecord
        }
        settings = committed
        settingsSuccessfulWriteCount += 1
        return committed
    }

    func saveToday(
        _ proposed: TodayRecord,
        expectedRevision: RecordRevision?
    ) async throws -> TodayRecord {
        todaySaveCount += 1
        if shouldHoldNextTodaySave {
            await withCheckedContinuation { continuation in
                heldTodaySaveContinuation = continuation
            }
            shouldHoldNextTodaySave = false
        }
        if let error = nextTodaySaveError {
            nextTodaySaveError = nil
            throw error
        }
        if todayDamage != nil {
            throw PersistenceError.damagedRecordRequiresRecovery(.today)
        }
        let actual = today?.revision
        guard expectedRevision == actual else {
            throw PersistenceError.revisionConflict(expected: expectedRevision, actual: actual)
        }
        let committed = proposed.replacingRevision(try (actual ?? .proposed).next())
        do {
            try committed.validated()
        } catch {
            throw PersistenceError.invalidProposedRecord
        }
        today = committed
        return committed
    }

    func recoverSettings(_ proposed: SettingsRecord) throws -> SettingsRecord {
        guard settingsDamage != nil else {
            throw PersistenceError.damagedRecordRequiresRecovery(.settings)
        }
        let committed = proposed.replacingRevision(.init(rawValue: 1))
        do {
            try committed.validated()
        } catch {
            throw PersistenceError.invalidProposedRecord
        }
        settings = committed
        settingsDamage = nil
        settingsSuccessfulWriteCount += 1
        return committed
    }

    func commitSaveSettings(_ intent: SettingsCommitIntent) async throws -> SettingsCommitResult {
        settingsSaveCount += 1
        if shouldHoldNextSettingsSave {
            shouldHoldNextSettingsSave = false
            isHoldingSettingsSave = true
            await withCheckedContinuation { continuation in
                heldSettingsSaveContinuation = continuation
            }
            isHoldingSettingsSave = false
        }
        if !settingsSaveErrors.isEmpty {
            let error = settingsSaveErrors.removeFirst()
            if let replacement = settingsReplacementOnNextSaveFailure {
                settings = replacement
                settingsDamage = nil
                settingsReplacementOnNextSaveFailure = nil
            }
            throw error
        }
        let actualToken: SettingsRecordToken
        if settingsDamage != nil { actualToken = settingsDamageToken }
        else if let settings { actualToken = .loaded(settings.revision) }
        else { actualToken = .missing }
        guard intent.expectedToken == actualToken else {
            let actualRevision = settings?.revision
            let expectedRevision: RecordRevision?
            if case let .loaded(revision) = intent.expectedToken { expectedRevision = revision }
            else { expectedRevision = nil }
            throw PersistenceError.revisionConflict(expected: expectedRevision, actual: actualRevision)
        }
        guard try CanonicalRecordEncoder.encode(intent.committedRecord) == intent.canonicalBytes else {
            throw PersistenceError.invalidProposedRecord
        }
        try intent.committedRecord.validated()
        settingsTemporaryWriteCount += 1
        settings = intent.committedRecord
        settingsDamage = nil
        settingsSuccessfulWriteCount += 1
        settingsCommitSuccessObserver?()
        return .init(commandID: intent.commandID, record: settings!)
    }

    func observeStartTodayCommit(_ observer: @escaping @Sendable () -> Void) {
        startTodayCommitObserver = observer
    }

    func commitStartToday(_ intent: StartTodayCommitIntent) throws -> StartTodayCommitResult {
        startTodayCommitObserver?()
        resetTodayCount += 1
        if let error = nextResetError {
            nextResetError = nil
            throw error
        }
        let actualSettingsToken: SettingsRecordToken
        if settingsDamage != nil { actualSettingsToken = settingsDamageToken }
        else if let settings { actualSettingsToken = .loaded(settings.revision) }
        else { actualSettingsToken = .missing }
        guard actualSettingsToken == intent.expectedSettingsToken else {
            throw PersistenceError.revisionConflict(expected: nil, actual: settings?.revision)
        }
        guard let today, today.revision == intent.expectedTodayRevision else {
            throw PersistenceError.revisionConflict(
                expected: intent.expectedTodayRevision,
                actual: today?.revision
            )
        }
        self.today = nil
        return .init(commandID: intent.commandID)
    }

    func resetDamagedSettingsToMissing(expectedToken: SettingsRecordToken) throws {
        guard settingsDamage != nil, expectedToken == settingsDamageToken else {
            throw PersistenceError.revisionConflict(expected: nil, actual: settings?.revision)
        }
        settings = nil
        settingsDamage = nil
    }

    func resetToday() throws {
        resetTodayCount += 1
        if let error = nextResetError {
            nextResetError = nil
            throw error
        }
        today = nil
        todayDamage = nil
    }

    func resetToday(expectedToken: TodayRecordToken) throws {
        resetTodayCount += 1
        if let error = nextResetError {
            nextResetError = nil
            throw error
        }
        let actual: TodayRecordToken
        if todayDamage != nil { actual = todayDamageToken }
        else if let today { actual = .loaded(today.revision) }
        else { actual = .missing }
        guard actual == expectedToken else {
            let expectedRevision: RecordRevision?
            if case let .loaded(revision) = expectedToken { expectedRevision = revision }
            else { expectedRevision = nil }
            throw PersistenceError.revisionConflict(
                expected: expectedRevision,
                actual: today?.revision
            )
        }
        today = nil
        todayDamage = nil
    }

    func failNextSettingsSave(with error: PersistenceError) {
        settingsSaveErrors.append(error)
    }

    func observeSettingsCommitSuccess(_ observer: @escaping @Sendable () -> Void) {
        settingsCommitSuccessObserver = observer
    }

    func holdNextSettingsSave() {
        shouldHoldNextSettingsSave = true
    }

    func waitUntilSettingsSaveIsHeld() async {
        while !isHoldingSettingsSave {
            await Task.yield()
        }
    }

    func resumeHeldSettingsSave() {
        heldSettingsSaveContinuation?.resume()
        heldSettingsSaveContinuation = nil
    }

    func failNextSettingsSave(
        with error: PersistenceError,
        thenReplaceSettingsWith replacement: SettingsRecord
    ) {
        settingsSaveErrors.append(error)
        settingsReplacementOnNextSaveFailure = replacement
    }

    func failSettingsSaves(with errors: [PersistenceError]) {
        settingsSaveErrors.append(contentsOf: errors)
    }

    func failNextTodaySave(with error: PersistenceError) {
        nextTodaySaveError = error
    }

    func failNextReset(with error: PersistenceError) {
        nextResetError = error
    }

    func holdNextTodaySave() {
        shouldHoldNextTodaySave = true
    }

    func waitUntilTodaySaveIsHeld() async {
        while heldTodaySaveContinuation == nil {
            await Task.yield()
        }
    }

    func releaseHeldTodaySave() {
        heldTodaySaveContinuation?.resume()
        heldTodaySaveContinuation = nil
    }

    func currentSettings() -> SettingsRecord? { settings }
    func currentToday() -> TodayRecord? { today }
    func currentSettingsToken() -> SettingsRecordToken {
        if settingsDamage != nil { return settingsDamageToken }
        if let settings { return .loaded(settings.revision) }
        return .missing
    }
    func currentTodayToken() -> TodayRecordToken {
        if todayDamage != nil { return todayDamageToken }
        if let today { return .loaded(today.revision) }
        return .missing
    }
    func currentSettingsCanonicalBytes() throws -> Data? {
        if settingsDamage != nil {
            guard case let .damaged(bytes) = settingsDamageToken else { return nil }
            return bytes
        }
        guard let settings else { return nil }
        return try CanonicalRecordEncoder.encode(settings)
    }

    func currentTodayCanonicalBytes() throws -> Data? {
        if todayDamage != nil {
            guard case let .damaged(bytes) = todayDamageToken else { return nil }
            return bytes
        }
        guard let today else { return nil }
        return try CanonicalRecordEncoder.encode(today)
    }

    func replaceSettingsExternally(_ record: SettingsRecord?) {
        settings = record
        settingsDamage = nil
        settingsExternalWriteCount += 1
    }

    func replaceTodayExternally(_ record: TodayRecord?) {
        today = record
        todayDamage = nil
    }
}

@MainActor
final class PanelControllerSpy: PanelControlling {
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var restoreCount = 0
    private(set) var lastShowPersist: Bool?
    private(set) var lastShowFocus: Bool?
    var restoredVisibility = true
    var preferences = PanelRuntimePreferences()
    private var visibilityHandler: (@MainActor (Bool) -> Void)?

    func restore() async -> Bool {
        restoreCount += 1
        return restoredVisibility
    }

    func show(persist: Bool, focus: Bool) {
        showCount += 1
        lastShowPersist = persist
        lastShowFocus = focus
        visibilityHandler?(true)
    }

    func hide(persist: Bool) {
        hideCount += 1
        visibilityHandler?(false)
    }

    func resetToDefaultPlacement() async -> Bool { true }

    func runtimePreferences() -> PanelRuntimePreferences { preferences }

    func setAlwaysOnTop(_ value: Bool) async -> Bool {
        preferences.alwaysOnTop = value
        return true
    }

    func setLockPanelPosition(_ value: Bool) async -> Bool {
        preferences.lockPanelPosition = value
        return true
    }

    func setHideInFullScreen(_ value: Bool) async -> Bool {
        preferences.hideInFullScreen = value
        return true
    }

    func setVisibilityChangeHandler(_ handler: @escaping @MainActor (Bool) -> Void) {
        visibilityHandler = handler
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}


/// Same-container DEBUG bootstrap for LaunchServices: sandbox callers cannot
/// pass OpenConfiguration.environment or .arguments. Per-root request/claim
/// files are retained; only this attempt's fixed transient request link is removed.
@MainActor
final class Stage9IsolatedApplicationProcess {
    private let application: NSRunningApplication
    private let request: Stage9RecoveryBootstrap.Request
    private static var launchFailureLatched = false
    var processIdentifier: pid_t { application.processIdentifier }
    var isRunning: Bool { !application.isTerminated }
    private var output: URL { URL(fileURLWithPath: request.output) }
    private var claimURL: URL {
        URL(fileURLWithPath: request.root).appendingPathComponent("bootstrap-claim-\(request.nonce).json")
    }
    private init(application: NSRunningApplication, request: Stage9RecoveryBootstrap.Request) {
        self.application = application
        self.request = request
    }
    private final class LaunchCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NSRunningApplication, Error>?
        init(_ continuation: CheckedContinuation<NSRunningApplication, Error>) { self.continuation = continuation }
        func finish(_ result: Result<NSRunningApplication, Error>) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return false }
            pending.resume(with: result)
            return true
        }
    }
    static func launch(root: URL, mode: String, output: URL,
                       time: TimestampMilliseconds) async throws -> Stage9IsolatedApplicationProcess {
#if !STAGE9_ISOLATED_TEST_BUILD
        throw NSError(domain: "Stage9RequiresFailClosedLocalTestBuild", code: 1)
#else
        guard !launchFailureLatched else { throw NSError(domain: "Stage9LaunchFailureLatched", code: 1) }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let output = output.standardizedFileURL.resolvingSymlinksInPath()
        let bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let now = Date().timeIntervalSince1970
        let request = Stage9RecoveryBootstrap.Request(schema: 1, root: root.path, output: output.path,
            bundle: bundle.path, parentPID: ProcessInfo.processInfo.processIdentifier, nonce: UUID().uuidString,
            mode: mode, time: time.rawValue, createdAt: now, expiresAt: now + 60)
        // ParentPID intentionally equals this process while constructing the request;
        // the child validation additionally requires a distinct live parent.
        guard root.deletingLastPathComponent().path == FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath().path,
              root.lastPathComponent.hasPrefix("IncomeClockRecovery-"),
              output.deletingLastPathComponent().path == root.path,
              !FileManager.default.fileExists(atPath: output.path),
              ["commit", "restore", "earning-commit", "earning-restore", "prior-day-restore", "theme-restore"].contains(mode) else {
            throw NSError(domain: "Stage9InvalidIsolatedLaunch", code: 1)
        }
        let archive = root.appendingPathComponent("bootstrap-request-\(request.nonce).json")
        try JSONEncoder().encode(request).write(to: archive, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        // link(2) publishes the complete file atomically and refuses an existing
        // marker. It cannot overwrite another pending or failed request.
        try FileManager.default.linkItem(at: archive, to: Stage9RecoveryBootstrap.markerURL)
        let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier:
            try XCTUnwrap(Bundle.main.bundleIdentifier)).map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        // Intentionally empty: documented as ignored for sandboxed callers.
        configuration.arguments = []
        configuration.environment = [:]
        var owned: Stage9IsolatedApplicationProcess?
        do {
            let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                let completion = LaunchCompletion(continuation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    _ = completion.finish(.failure(NSError(domain: "Stage9LaunchCallbackTimeout", code: 1)))
                }
                NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { application, error in
                    let result: Result<NSRunningApplication, Error>
                    if let error { result = .failure(error) }
                    else if let application { result = .success(application) }
                    else { result = .failure(NSError(domain: "Stage9MissingLaunchedApplication", code: 1)) }
                    let accepted = completion.finish(result)
                    if !accepted, let application {
                        Task { @MainActor in
                            if !existingPIDs.contains(application.processIdentifier),
                               application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == bundle.path {
                                let late = Stage9IsolatedApplicationProcess(application: application, request: request)
                                late.terminateIfRunning()
                                do { try await late.waitForTermination() }
                                catch { XCTFail("Late isolated launch cleanup did not terminate: \(error)") }
                            }
                        }
                    }
                }
            }
            guard !existingPIDs.contains(application.processIdentifier),
                  application.processIdentifier != request.parentPID,
                  application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == bundle.path else {
                throw NSError(domain: "Stage9UnexpectedLaunchedApplication", code: 1)
            }
            let child = Stage9IsolatedApplicationProcess(application: application, request: request)
            owned = child
            // An unclaimed instance never gets a 15-second business-result wait.
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: child.claimURL.path), child.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let claim = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: child.claimURL)) as? [String: Any])
            guard claim["pid"] as? Int32 == child.processIdentifier,
                  claim["parentPID"] as? Int32 == request.parentPID,
                  claim["nonce"] as? String == request.nonce,
                  claim["root"] as? String == request.root,
                  claim["bundle"] as? String == request.bundle,
                  claim["mode"] as? String == request.mode else {
                throw NSError(domain: "Stage9InvalidBootstrapClaim", code: 1)
            }
            try removeOwnMarker(request)
            return child
        } catch {
            launchFailureLatched = true // No next launch can consume a late callback's request.
            if let owned {
                owned.terminateIfRunning()
                do { try await owned.waitForTermination() }
                catch { XCTFail("Owned launch cleanup failed: \(error)") }
            }
            do { try removeOwnMarker(request) }
            catch { XCTFail("Bootstrap marker cleanup failed: \(error)") }
            throw error
        }
#endif
    }
    private static func removeOwnMarker(_ request: Stage9RecoveryBootstrap.Request) throws {
        var metadata = stat()
        if lstat(Stage9RecoveryBootstrap.markerURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw NSError(domain: "Stage9MarkerStatFailed", code: 1) }
            return
        }
        guard try Stage9RecoveryBootstrap.readRequest(at: Stage9RecoveryBootstrap.markerURL) == request else {
            throw NSError(domain: "Stage9RefusedForeignMarkerCleanup", code: 1)
        }
        try FileManager.default.removeItem(at: Stage9RecoveryBootstrap.markerURL)
    }
    private func writeSelfTerminationRequest() throws {
        let control: [String: Any] = ["pid": processIdentifier, "nonce": request.nonce,
            "root": request.root, "mode": request.mode, "signal": SIGKILL]
        try JSONSerialization.data(withJSONObject: control, options: [.sortedKeys])
            .write(to: output.appendingPathExtension("signal.json"), options: .atomic)
    }
    func terminateIfRunning() {
        guard isRunning else { return }
        do {
            try writeSelfTerminationRequest()
            print("STAGE9 owned cleanup requested authenticated self-SIGKILL pid=\(processIdentifier)")
        } catch { XCTFail("Cannot request isolated self-termination: \(error)") }
    }
    func requestSelfSIGKILLAndWait() async throws -> [String: Any] {
        guard isRunning else { throw NSError(domain: "Stage9WriterWasNotAlive", code: 1) }
        try writeSelfTerminationRequest()
        let receiptURL = output.appendingPathExtension("signal-receipt.json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: receiptURL.path), isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        guard receipt["pid"] as? Int32 == processIdentifier,
              receipt["nonce"] as? String == request.nonce,
              receipt["root"] as? String == request.root,
              receipt["mode"] as? String == request.mode,
              receipt["signal"] as? Int32 == SIGKILL,
              receipt["sender"] as? String == "self",
              receipt["phase"] as? String == "before-kill-syscall" else {
            throw NSError(domain: "Stage9InvalidSelfSignalReceipt", code: 1)
        }
        try await waitForTermination()
        return receipt
    }
    func readResult() async throws -> [String: Any] {
        do {
            let deadline = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: output.path), isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
            guard value["pid"] as? Int32 == processIdentifier,
                  value["root"] as? String == request.root,
                  value["bundle"] as? String == request.bundle,
                  value["nonce"] as? String == request.nonce,
                  value["mode"] as? String == request.mode,
                  value["harnessResultComplete"] as? Bool == true else {
                throw NSError(domain: "Stage9InvalidProcessReceipt", code: 1)
            }
            if request.mode != "commit" && request.mode != "earning-commit" {
                try Data(request.nonce.utf8).write(to: output.appendingPathExtension("ack"), options: .atomic)
            }
            return value
        } catch {
            Self.launchFailureLatched = true
            terminateIfRunning()
            do { try await waitForTermination() }
            catch { XCTFail("Owned result failure cleanup failed: \(error)") }
            throw error
        }
    }
    func waitForTermination() async throws {
        let deadline = Date().addingTimeInterval(5)
        while isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !isRunning else { throw NSError(domain: "Stage9ProcessDidNotTerminate", code: 1) }
    }
}
