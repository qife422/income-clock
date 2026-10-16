import Foundation

protocol BusinessRecordRepository: Sendable {
    func loadSettings() async -> RecordLoadResult<SettingsRecord>
    func loadSettingsForBusiness() async -> SettingsTypedLoadResult
    func loadToday() async -> RecordLoadResult<TodayRecord>
    func loadTodayForBusiness() async -> TodayTypedLoadResult
    func saveSettings(
        _ proposed: SettingsRecord,
        expectedRevision: RecordRevision?
    ) async throws -> SettingsRecord
    func saveToday(
        _ proposed: TodayRecord,
        expectedRevision: RecordRevision?
    ) async throws -> TodayRecord
    func recoverSettings(_ proposed: SettingsRecord) async throws -> SettingsRecord
    func commitSaveSettings(_ intent: SettingsCommitIntent) async throws -> SettingsCommitResult
    func commitStartToday(_ intent: StartTodayCommitIntent) async throws -> StartTodayCommitResult
    func resetDamagedSettingsToMissing(expectedToken: SettingsRecordToken) async throws
    func resetToday(expectedToken: TodayRecordToken) async throws
    func resetToday() async throws
}

extension RecordRepositoryActor: BusinessRecordRepository {}

enum BusinessCommandSource: Equatable, Sendable {
    case panel
    case menuBar
    case settings
    case system
}

enum BusinessCommand: Equatable, Sendable {
    case saveWorkRules(WorkRuleSettingsInput)
    case clockIn
    case requestClockOut
    case confirmClockOut
    case cancelConfirmation
    case requestTodayReset
    case confirmTodayReset
    case requestStartToday
    case confirmStartToday
    case requestSettingsReset
    case confirmSettingsReset

    var kind: BusinessCommandKind {
        switch self {
        case .saveWorkRules: .saveWorkRules
        case .clockIn: .clockIn
        case .requestClockOut: .requestClockOut
        case .confirmClockOut: .confirmClockOut
        case .cancelConfirmation: .cancelConfirmation
        case .requestTodayReset: .requestTodayReset
        case .confirmTodayReset: .confirmTodayReset
        case .requestStartToday: .requestStartToday
        case .confirmStartToday: .confirmStartToday
        case .requestSettingsReset: .requestSettingsReset
        case .confirmSettingsReset: .confirmSettingsReset
        }
    }
}

enum BusinessCommandKind: Equatable, Sendable {
    case saveWorkRules
    case clockIn
    case requestClockOut
    case confirmClockOut
    case cancelConfirmation
    case requestTodayReset
    case confirmTodayReset
    case requestStartToday
    case confirmStartToday
    case requestSettingsReset
    case confirmSettingsReset
}

enum BusinessCommandRejection: Equatable, Sendable {
    case storeNotRestored
    case commandInFlight
    case invalidState
    case clockInAfterScheduledEnd
    case confirmationRequired
    case previousDayCleanupPending
    case incompletePreviousDay
    case invalidWorkdayTransition
}

enum BusinessFailure: Error, Equatable, Sendable {
    case persistence(PersistenceError)
    case scheduleTime(ScheduleTimeError)
    case settingsRead(RecordDamageIssue)
    case workdayTransition(BusinessCommandRejection)
    case invalidCalendar
    case calculation(EarningsCalculationError)
}

enum SaveSettingsPlanCheckpoint: CaseIterable, Equatable, Sendable {
    case inputValidation
    case committedRecordValidation
    case settingsTypedLoad
    case todayTypedLoad
    case targetBusinessStateConstruction
    case amountAndTimeDerivation
    case targetBusinessViewStateConstruction
    case successEventConstruction
    case encoding
    case commitIntentConstruction
}

protocol SaveSettingsPlanFaultInjecting: Sendable {
    func checkpoint(_ checkpoint: SaveSettingsPlanCheckpoint) throws
}

struct NoSaveSettingsPlanFaultInjector: SaveSettingsPlanFaultInjecting {
    func checkpoint(_ checkpoint: SaveSettingsPlanCheckpoint) throws {
        _ = checkpoint
    }
}

enum SaveSettingsDerivedOperation: CaseIterable, Equatable, Hashable, Sendable {
    case stateDerivation
    case earningsCalculation
    case businessViewStateConstruction
}

protocol SaveSettingsExecutionObserving: Sendable {
    func willInvokeDerivedOperation(_ operation: SaveSettingsDerivedOperation)
    func didPublishSuccess()
    func willParseSettings()
    func willReconcile()
}

extension SaveSettingsExecutionObserving {
    func willParseSettings() {}
    func willReconcile() {}
}

struct NoSaveSettingsExecutionObserver: SaveSettingsExecutionObserving {
    func willInvokeDerivedOperation(_ operation: SaveSettingsDerivedOperation) {
        _ = operation
    }

    func didPublishSuccess() {}
}

enum SaveSettingsContextConsumer: CaseIterable, Equatable, Hashable, Sendable {
    case commandEntry
    case settingsTypedLoad
    case todayTypedLoad
    case settingsToken
    case todayToken
    case resolver
    case targetState
    case businessViewState
    case successEvent
    case repositoryIntent
    case repositoryWrite
    case repositoryEvent
    case successPublication
}

protocol SaveSettingsCommandContextObserving: Sendable {
    func observe(_ context: BusinessCommandContext, consumer: SaveSettingsContextConsumer)
}

struct NoSaveSettingsCommandContextObserver: SaveSettingsCommandContextObserving {
    func observe(_ context: BusinessCommandContext, consumer: SaveSettingsContextConsumer) {
        _ = context
        _ = consumer
    }
}

enum SaveSettingsResultDeliveryKind: Equatable, Sendable {
    case validationFailure
    case errorFailure
    case conflictFailure
    case ioFailure
    case committed
}

struct SaveSettingsResultDelivery {
    let context: BusinessCommandContext
    let kind: SaveSettingsResultDeliveryKind
    private let action: @MainActor () -> Void

    init(
        context: BusinessCommandContext,
        kind: SaveSettingsResultDeliveryKind,
        action: @escaping @MainActor () -> Void
    ) {
        self.context = context
        self.kind = kind
        self.action = action
    }

    @MainActor
    func deliver() {
        action()
    }
}

protocol SaveSettingsResultDeliveryControlling {
    @MainActor
    func deliver(_ delivery: SaveSettingsResultDelivery)
}

struct ImmediateSaveSettingsResultDeliveryController: SaveSettingsResultDeliveryControlling {
    @MainActor
    func deliver(_ delivery: SaveSettingsResultDelivery) {
        delivery.deliver()
    }
}

struct BusinessCommandResultGuard {
    static func accepts(
        commandID: UUID,
        expectedStoreGeneration: UInt64,
        activeCommandID: UUID?,
        currentStoreGeneration: UInt64
    ) -> Bool {
        activeCommandID == commandID && currentStoreGeneration == expectedStoreGeneration
    }
}

struct BusinessCommandContext: Equatable, Sendable {
    let commandID: UUID
    let timestampMs: TimestampMilliseconds
    let commandTimeZoneIdentifier: String
    let commandDateKey: WorkdayKey
}

struct SettingsReadErrorViewState: Equatable, Sendable {
    let issue: RecordDamageIssue
    let isBlocking: Bool
}

struct SaveSettingsPlan: Equatable, Sendable {
    let context: BusinessCommandContext
    let committedRecord: SettingsRecord
    let commitIntent: SettingsCommitIntent
    let targetViewState: BusinessViewState
    let targetTodayRecord: TodayRecord?
    let targetTodayRecoveryReason: RecoveryReason?
    let targetTodayToken: TodayRecordToken
    let expectedStoreGeneration: UInt64
    let successEvent: BusinessFeedback
}

struct StartTodayPlan: Equatable, Sendable {
    let context: BusinessCommandContext
    let commitIntent: StartTodayCommitIntent
    let targetViewState: BusinessViewState
}

struct WorkRuleSettingsInput: Equatable, Sendable {
    let dailyWageCents: Int64
    let workStartMinuteOfDay: Int
    let workEndMinuteOfDay: Int
}

struct ScheduleTimeErrorViewState: Equatable, Sendable {
    enum Context: Equatable, Sendable {
        case activeSchedule
        case proposedSettings
    }

    let error: ScheduleTimeError
    let context: Context
}

enum BusinessCommandOutcome: Equatable, Sendable {
    case committed
    case confirmationPresented
    case confirmationCancelled
    case rejected(BusinessCommandRejection)
    case failed(BusinessFailure)
}

enum BusinessEarnedAmount: Equatable, Sendable {
    case hidden
    case live(LiveEarnedMilliYuan)
    case rounded(RoundedEarnedCents)
}

struct ClockOutEstimate: Equatable, Sendable {
    let roundedEarnedCents: RoundedEarnedCents
    let earnedDuration: DurationMilliseconds
    let sampledAt: TimestampMilliseconds
}

enum BusinessConfirmation: Equatable, Sendable {
    case clockOut(ClockOutEstimate)
    case resetToday
    case startToday
    case resetSettings
}

enum BusinessCommandPhase: Equatable, Sendable {
    case idle
    case checking(BusinessCommandContext)
    case saving(BusinessCommandContext, targetRevision: RecordRevision)
}

struct SettingsSaveReceipt: Equatable, Sendable {
    let context: BusinessCommandContext
    let committedRevision: RecordRevision
}

enum BusinessFeedback: Equatable, Sendable {
    case settingsSaved(SettingsSaveReceipt)
    case clockInSucceeded
    case clockOutSucceeded
    case todayResetSucceeded
    case todayStarted
    case settingsResetSucceeded
    case settingsRecoveryRequired(RecordDamageIssue)
    case previousDayCleanupFailed(PersistenceError)
    case restoreFailed(BusinessFailure)
    case commandFailed(BusinessCommandKind, BusinessFailure)
}

struct BusinessViewState: Equatable, Sendable {
    let state: WorkdayState
    let recoveryReason: RecoveryReason?
    let amount: BusinessEarnedAmount
    let earnedDuration: DurationMilliseconds?
    let scheduledProgress: Double?
    let remainingToStart: DurationMilliseconds?
    let remainingToEnd: DurationMilliseconds?
    let clockInAt: TimestampMilliseconds?
    let clockOutAt: TimestampMilliseconds?
    let todayDateKey: String?
    let todayTimeZoneIdentifier: String?
    let isPreviousWorkday: Bool
    let clockOutDateKey: String?
    let canClockIn: Bool
    let canRequestClockOut: Bool
    let canRequestTodayReset: Bool
    let canRequestStartToday: Bool
    let canRequestSettingsReset: Bool
    let previousDayCleanupPending: Bool
}

// Test-only injection at real startToday preflight boundaries; production is no-op.
enum StartTodayPreflightPoint: String, CaseIterable, Sendable {
    case commandContext, typedLoads, currentWorkday, settingsClassification, schedule, targetViewState, commitIntent
}
protocol StartTodayPreflightObserving {
    @MainActor func check(_ point: StartTodayPreflightPoint, context: BusinessCommandContext) throws
}
struct NoStartTodayPreflightObserver: StartTodayPreflightObserving {
    func check(_ point: StartTodayPreflightPoint, context: BusinessCommandContext) throws {}
}
