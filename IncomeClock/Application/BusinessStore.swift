import Foundation
import Combine

@MainActor
final class BusinessStore: ObservableObject {
    private struct DerivedSnapshot {
        let result: StateDerivationResult
        let currentDateKey: WorkdayKey
        let currentSettings: WorkdaySettingsSnapshot?
        let today: TodayRecordSnapshot?
        let now: TimestampMilliseconds
    }

    private let repository: any BusinessRecordRepository
    private let nowProvider: any NowProvider
    private let timeZoneIdentifierProvider: any TimeZoneIdentifierProvider
    private let workdayCalendar: BusinessWorkdayCalendar
    private let saveSettingsPlanFaultInjector: any SaveSettingsPlanFaultInjecting
    private let saveSettingsExecutionObserver: any SaveSettingsExecutionObserving
    private let saveSettingsCommandContextObserver: any SaveSettingsCommandContextObserving
    private let saveSettingsResultDeliveryController: any SaveSettingsResultDeliveryControlling
    private let startTodayPreflightObserver: any StartTodayPreflightObserving
    private let notificationService: any NotificationServicing

    private var settingsRecord: SettingsRecord?
    private var settingsToken: SettingsRecordToken = .missing
    private var settingsDamage: RecordDamageIssue?
    private var todayRecord: TodayRecord?
    private var todayToken: TodayRecordToken = .missing
    private var todayRecoveryReason: RecoveryReason?
    private var activeCommandID: UUID?
    private(set) var stateGeneration: UInt64 = 0

    @Published private(set) var viewState: BusinessViewState?
    @Published private(set) var settingsReadErrorViewState: SettingsReadErrorViewState?
    @Published private(set) var scheduleTimeErrorViewState: ScheduleTimeErrorViewState?
    @Published private(set) var confirmation: BusinessConfirmation?
    @Published private(set) var feedback: BusinessFeedback?
    @Published private(set) var isRestoring = false
    @Published private(set) var isCommandInFlight = false
    @Published private(set) var commandPhase: BusinessCommandPhase = .idle
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var isNotificationPreferenceInFlight = false
    @Published private(set) var notificationPreferenceError: NotificationFeatureError?
    @Published private(set) var notificationDiagnostics: [NotificationDiagnosticEvent] = []
    private(set) var commandPhaseHistory: [BusinessCommandPhase] = [.idle]

    var currentWorkRules: WorkRuleSettingsInput? {
        settingsRecord.map {
            WorkRuleSettingsInput(
                dailyWageCents: $0.dailyWageCents,
                workStartMinuteOfDay: $0.workStartMinuteOfDay,
                workEndMinuteOfDay: $0.workEndMinuteOfDay
            )
        }
    }

    var hasDamagedSettings: Bool { settingsDamage != nil }

    var hasBlockingScheduleError: Bool {
        guard settingsDamage == nil, let error = scheduleTimeErrorViewState else { return false }
        if error.context == .activeSchedule { return true }
        // The rejected draft keeps its field diagnostic while an already-invalid
        // committed schedule still has no verified business state to present.
        return error.context == .proposedSettings && settingsRecord != nil && viewState == nil
    }

    // Read-only validation observations. These do not participate in app behavior.
    var settingsRecordForValidation: SettingsRecord? { settingsRecord }
    var settingsTokenForValidation: SettingsRecordToken { settingsToken }
    var todayRecordForValidation: TodayRecord? { todayRecord }
    var todayTokenForValidation: TodayRecordToken { todayToken }

    convenience init(repository: any BusinessRecordRepository, nowProvider: any NowProvider,
                     timeZoneIdentifier: String,
                     notificationService: any NotificationServicing = UnavailableNotificationService()) throws {
        try self.init(
            repository: repository,
            nowProvider: nowProvider,
            timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(identifier: timeZoneIdentifier),
            notificationService: notificationService
        )
    }

    init(
        repository: any BusinessRecordRepository,
        nowProvider: any NowProvider,
        timeZoneIdentifierProvider: any TimeZoneIdentifierProvider,
        scheduleResolver: any LocalScheduleResolving = LocalScheduleResolver(),
        saveSettingsPlanFaultInjector: any SaveSettingsPlanFaultInjecting = NoSaveSettingsPlanFaultInjector(),
        saveSettingsExecutionObserver: any SaveSettingsExecutionObserving = NoSaveSettingsExecutionObserver(),
        saveSettingsCommandContextObserver: any SaveSettingsCommandContextObserving =
            NoSaveSettingsCommandContextObserver(),
        saveSettingsResultDeliveryController: any SaveSettingsResultDeliveryControlling =
            ImmediateSaveSettingsResultDeliveryController(),
        startTodayPreflightObserver: any StartTodayPreflightObserving = NoStartTodayPreflightObserver(),
        notificationService: any NotificationServicing = UnavailableNotificationService()
    ) throws {
        self.repository = repository
        self.nowProvider = nowProvider
        self.timeZoneIdentifierProvider = timeZoneIdentifierProvider
        self.saveSettingsPlanFaultInjector = saveSettingsPlanFaultInjector
        self.saveSettingsExecutionObserver = saveSettingsExecutionObserver
        self.saveSettingsCommandContextObserver = saveSettingsCommandContextObserver
        self.saveSettingsResultDeliveryController = saveSettingsResultDeliveryController
        self.startTodayPreflightObserver = startTodayPreflightObserver
        self.notificationService = notificationService
        workdayCalendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: "UTC",
            scheduleResolver: scheduleResolver,
            settingsParsingObserver: { saveSettingsExecutionObserver.willParseSettings() }
        )
    }

    func restore() async {
        guard !isRestoring, !isCommandInFlight else { return }
        isRestoring = true
        defer { isRestoring = false }
        let context: BusinessCommandContext
        do { context = try commandContext(commandID: UUID()) }
        catch { publishRestoreFailure(.invalidCalendar); return }
        async let settingsLoad = repository.loadSettingsForBusiness()
        async let todayLoad = repository.loadTodayForBusiness()
        let (loadedSettings, loadedToday) = await (settingsLoad, todayLoad)
        applySettingsLoad(loadedSettings)
        applyTodayLoad(loadedToday)
        stateGeneration &+= 1
        publishSettingsError()
        do {
            try reconcile(context: context)
            await coordinateNotificationForToday(
                context: context,
                allowAdd: settingsRecord?.notificationsEnabled == true
            )
        }
        catch let error as ScheduleTimeError { publishActiveScheduleError(error) }
        catch let error as EarningsCalculationError { publishRestoreFailure(.calculation(error)) }
        catch { publishRestoreFailure(.invalidCalendar) }
    }

    func refresh() async {
        guard viewState != nil || settingsReadErrorViewState != nil || scheduleTimeErrorViewState != nil,
              !isRestoring, !isCommandInFlight else { return }
        do { try reconcile(context: commandContext(commandID: UUID())) }
        catch let error as ScheduleTimeError {
            publishActiveScheduleError(error, preservingProposedSettingsError: true)
        }
        catch let error as EarningsCalculationError { publishRestoreFailure(.calculation(error)) }
        catch { publishRestoreFailure(.invalidCalendar) }
    }

    func clearFeedback() { feedback = nil }

    func setNotificationsEnabled(_ enabled: Bool) async -> Stage6PreferenceOutcome {
        guard !isRestoring, !isCommandInFlight, !isNotificationPreferenceInFlight else {
            return .rejected
        }
        isNotificationPreferenceInFlight = true
        notificationPreferenceError = nil
        defer { isNotificationPreferenceInFlight = false }

        if enabled {
            let status: NotificationAuthorizationState
            do {
                status = try await notificationService.authorizationStatus()
            } catch {
                notificationPreferenceError = .permissionQueryFailed
                return .failed
            }
            let finalStatus: NotificationAuthorizationState
            if status == .notDetermined {
                do {
                    finalStatus = try await notificationService.requestAuthorization()
                } catch {
                    notificationPreferenceError = .permissionRequestFailed
                    return .failed
                }
            } else {
                finalStatus = status
            }
            guard finalStatus.permitsScheduling else {
                notificationPreferenceError = .permissionDenied
                return .failed
            }
        }

        let commandID = UUID()
        do {
            let context = try commandContext(commandID: commandID)
            try await commitSettingsFlag(context: context) { record in
                Self.settings(record, notificationsEnabled: enabled, updatedAt: context.timestampMs.rawValue)
            }
            if enabled {
                await coordinateNotificationForToday(context: context, allowAdd: true)
            }
            return .committed
        } catch {
            notificationPreferenceError = .settingsPersistenceFailed
            return .failed
        }
    }

    func persistLaunchAtLogin(_ enabled: Bool, commandID: UUID) async -> Stage6PreferenceOutcome {
        guard !isRestoring, !isCommandInFlight, !isNotificationPreferenceInFlight else {
            return .rejected
        }
        do {
            let context = try commandContext(commandID: commandID)
            try await commitSettingsFlag(context: context) { record in
                Self.settings(record, launchAtLogin: enabled, updatedAt: context.timestampMs.rawValue)
            }
            return .committed
        } catch {
            return .failed
        }
    }

    func send(_ command: BusinessCommand, source: BusinessCommandSource) async -> BusinessCommandOutcome {
        _ = source
        let permittedWithoutView: Bool
        switch command {
        case .saveWorkRules, .requestSettingsReset, .confirmSettingsReset: permittedWithoutView = true
        case .cancelConfirmation:
            permittedWithoutView = settingsDamage != nil && confirmation == .resetSettings
        default: permittedWithoutView = false
        }
        guard viewState != nil || permittedWithoutView, !isRestoring else {
            return .rejected(.storeNotRestored)
        }
        guard !isCommandInFlight else { return .rejected(.commandInFlight) }
        switch command {
        case .cancelConfirmation:
            confirmation = nil
            return .confirmationCancelled
        case .requestTodayReset:
            guard viewState?.state == .recoveryRequired else { return .rejected(.invalidState) }
            confirmation = .resetToday
            return .confirmationPresented
        case .requestStartToday:
            guard viewState?.state == .completed,
                  viewState?.canRequestStartToday == true else {
                return .rejected(.invalidWorkdayTransition)
            }
            confirmation = .startToday
            return .confirmationPresented
        case .requestSettingsReset:
            guard settingsDamage != nil else { return .rejected(.invalidState) }
            confirmation = .resetSettings
            return .confirmationPresented
        default:
            return await execute(command)
        }
    }

    private func execute(_ command: BusinessCommand) async -> BusinessCommandOutcome {
        isCommandInFlight = true
        let commandID = UUID()
        activeCommandID = commandID
        let commandGeneration = stateGeneration
        var saveSettingsContext: BusinessCommandContext?
        defer {
            if activeCommandID == commandID { activeCommandID = nil }
            setCommandPhase(.idle)
            isCommandInFlight = false
        }
        do {
            let context = try commandContext(commandID: commandID)
            switch command {
            case let .saveWorkRules(input):
                saveSettingsContext = context
                observeSaveSettingsContext(context, consumer: .commandEntry)
                setCommandPhase(.checking(context))
                let plan = try await buildSaveSettingsPlan(input, context: context)
                setCommandPhase(.saving(context, targetRevision: plan.committedRecord.revision))
                observeSaveSettingsContext(context, consumer: .repositoryWrite)
                let result = try await repository.commitSaveSettings(plan.commitIntent)
                observeSaveSettingsContext(context, consumer: .repositoryEvent)
                saveSettingsResultDeliveryController.deliver(.init(
                    context: context,
                    kind: .committed,
                    action: { [weak self] in
                        self?.publishCommittedSettings(plan: plan, result: result)
                    }
                ))
                return .committed
            case .clockIn:
                let outcome = try await clockIn(context: context)
                if outcome == .committed { feedback = .clockInSucceeded }
                return outcome
            case .requestClockOut:
                return try await requestClockOut(context: context)
            case .confirmClockOut:
                guard case .clockOut = confirmation else { return .rejected(.confirmationRequired) }
                try await commitClockOut(context: context)
                feedback = .clockOutSucceeded
                return .committed
            case .confirmTodayReset:
                guard confirmation == .resetToday, viewState?.state == .recoveryRequired else {
                    return .rejected(.confirmationRequired)
                }
                return try await resetToday(context: context)
            case .confirmStartToday:
                guard confirmation == .startToday else { return .rejected(.confirmationRequired) }
                let plan = try await buildStartTodayPlan(context: context)
                let result = try await repository.commitStartToday(plan.commitIntent)
                guard result.commandID == plan.context.commandID,
                      activeCommandID == result.commandID else { return .rejected(.commandInFlight) }
                todayRecord = nil
                todayRecoveryReason = nil
                todayToken = .missing
                viewState = plan.targetViewState
                confirmation = nil
                scheduleTimeErrorViewState = nil
                feedback = .todayStarted
                stateGeneration &+= 1
                return .committed
            case .confirmSettingsReset:
                guard confirmation == .resetSettings, settingsDamage != nil else {
                    return .rejected(.confirmationRequired)
                }
                try await resetDamagedSettings(context: context)
                return .committed
            case .cancelConfirmation, .requestTodayReset, .requestStartToday, .requestSettingsReset:
                return .rejected(.invalidState)
            }
        } catch let error as ScheduleTimeError {
            deliverSaveSettingsResult(
                context: saveSettingsContext,
                kind: .validationFailure
            ) { [weak self] in
                guard let self else { return }
                if BusinessCommandResultGuard.accepts(
                    commandID: commandID,
                    expectedStoreGeneration: commandGeneration,
                    activeCommandID: self.activeCommandID,
                    currentStoreGeneration: self.stateGeneration
                ) {
                    self.feedback = nil
                    if case .saveWorkRules = command {
                        self.scheduleTimeErrorViewState = .init(
                            error: error,
                            context: .proposedSettings
                        )
                    }
                }
            }
            return .failed(.scheduleTime(error))
        } catch let failure as BusinessFailure {
            deliverSaveSettingsResult(context: saveSettingsContext, kind: .errorFailure) {
                [weak self] in
                self?.publishCommandFailureIfCurrent(
                    failure, command: command, commandID: commandID,
                    expectedStoreGeneration: commandGeneration
                )
            }
            return .failed(failure)
        } catch let error as PersistenceError {
            let failure = BusinessFailure.persistence(error)
            let deliveryKind: SaveSettingsResultDeliveryKind
            switch error {
            case .revisionConflict: deliveryKind = .conflictFailure
            case .atomicWriteFailed: deliveryKind = .ioFailure
            default: deliveryKind = .errorFailure
            }
            deliverSaveSettingsResult(context: saveSettingsContext, kind: deliveryKind) {
                [weak self] in
                self?.publishCommandFailureIfCurrent(
                    failure, command: command, commandID: commandID,
                    expectedStoreGeneration: commandGeneration
                )
            }
            return .failed(failure)
        } catch let error as EarningsCalculationError {
            let failure = BusinessFailure.calculation(error)
            deliverSaveSettingsResult(context: saveSettingsContext, kind: .errorFailure) {
                [weak self] in
                self?.publishCommandFailureIfCurrent(
                    failure, command: command, commandID: commandID,
                    expectedStoreGeneration: commandGeneration
                )
            }
            return .failed(failure)
        } catch {
            let failure = BusinessFailure.invalidCalendar
            deliverSaveSettingsResult(context: saveSettingsContext, kind: .errorFailure) {
                [weak self] in
                self?.publishCommandFailureIfCurrent(
                    failure, command: command, commandID: commandID,
                    expectedStoreGeneration: commandGeneration
                )
            }
            return .failed(failure)
        }
    }

    private func observeSaveSettingsContext(
        _ context: BusinessCommandContext,
        consumer: SaveSettingsContextConsumer
    ) {
        saveSettingsCommandContextObserver.observe(context, consumer: consumer)
    }

    private func deliverSaveSettingsResult(
        context: BusinessCommandContext?,
        kind: SaveSettingsResultDeliveryKind,
        action: @escaping @MainActor () -> Void
    ) {
        guard let context else {
            action()
            return
        }
        saveSettingsResultDeliveryController.deliver(.init(
            context: context,
            kind: kind,
            action: action
        ))
    }

    private func loadSettingsForSaveSettingsPlan(
        context: BusinessCommandContext
    ) async throws -> SettingsTypedLoadResult {
        try saveSettingsPlanFaultInjector.checkpoint(.settingsTypedLoad)
        observeSaveSettingsContext(context, consumer: .settingsTypedLoad)
        return await repository.loadSettingsForBusiness()
    }

    private func loadTodayForSaveSettingsPlan(
        context: BusinessCommandContext
    ) async throws -> TodayTypedLoadResult {
        try saveSettingsPlanFaultInjector.checkpoint(.todayTypedLoad)
        observeSaveSettingsContext(context, consumer: .todayTypedLoad)
        return await repository.loadTodayForBusiness()
    }

    // Every potentially failing value is constructed before the repository CAS/write call.
    private func buildSaveSettingsPlan(
        _ input: WorkRuleSettingsInput,
        context: BusinessCommandContext
    ) async throws -> SaveSettingsPlan {
        async let freshSettings = loadSettingsForSaveSettingsPlan(context: context)
        async let freshToday = loadTodayForSaveSettingsPlan(context: context)
        let (settingsLoad, todayLoad) = try await (freshSettings, freshToday)
        observeSaveSettingsContext(context, consumer: .settingsToken)
        guard settingsLoad.token == settingsToken else {
            let expected: RecordRevision?
            let actual: RecordRevision?
            if case let .loaded(revision) = settingsToken { expected = revision } else { expected = nil }
            if case let .loaded(revision) = settingsLoad.token { actual = revision } else { actual = nil }
            throw PersistenceError.revisionConflict(expected: expected, actual: actual)
        }
        let token = settingsToken
        observeSaveSettingsContext(context, consumer: .todayToken)
        guard todayLoad.token == todayToken else {
            throw Self.todayTokenConflict(expected: todayToken, actual: todayLoad.token)
        }
        try saveSettingsPlanFaultInjector.checkpoint(.inputValidation)
        try Self.validateSettingsInput(input)
        let base: SettingsRecord?
        switch settingsLoad {
        case .missing, .damaged: base = nil
        case let .loaded(record, _): base = record
        }
        let proposed = Self.settings(
            applying: input,
            to: base,
            updatedAt: context.timestampMs.rawValue
        )
        let nextRevision: RecordRevision
        switch token {
        case let .loaded(revision): nextRevision = try revision.next()
        case .missing, .damaged, .unreadableDamage: nextRevision = .init(rawValue: 1)
        }
        let committedRecord = proposed.replacingRevision(nextRevision)
        try saveSettingsPlanFaultInjector.checkpoint(.committedRecordValidation)
        try committedRecord.validated()
        observeSaveSettingsContext(context, consumer: .resolver)
        _ = try workdayCalendar.settingsSnapshot(from: committedRecord,
            for: context.commandDateKey,
            timeZoneIdentifier: context.commandTimeZoneIdentifier)
        let components = Self.todayComponents(todayLoad)
        try saveSettingsPlanFaultInjector.checkpoint(.targetBusinessStateConstruction)
        observeSaveSettingsContext(context, consumer: .targetState)
        let snapshot = try buildSnapshot(settings: committedRecord,
            todayRecord: components.record,
            todayRecoveryReason: components.recoveryReason,
            context: context,
            beforeStateDerivation: {
                self.saveSettingsExecutionObserver.willInvokeDerivedOperation(.stateDerivation)
            })
        observeSaveSettingsContext(context, consumer: .businessViewState)
        let target = try makeViewState(
            from: snapshot,
            settingsAreDamaged: false,
            beforeAmountAndTimeDerivation: {
                try self.saveSettingsPlanFaultInjector.checkpoint(.amountAndTimeDerivation)
            },
            beforeEarningsCalculatorInvocation: {
                self.saveSettingsExecutionObserver.willInvokeDerivedOperation(.earningsCalculation)
            },
            beforeViewStateConstruction: {
                self.saveSettingsExecutionObserver.willInvokeDerivedOperation(
                    .businessViewStateConstruction
                )
                try self.saveSettingsPlanFaultInjector.checkpoint(.targetBusinessViewStateConstruction)
            }
        )
        try saveSettingsPlanFaultInjector.checkpoint(.successEventConstruction)
        observeSaveSettingsContext(context, consumer: .successEvent)
        let successEvent = BusinessFeedback.settingsSaved(.init(
            context: context,
            committedRevision: committedRecord.revision
        ))
        try saveSettingsPlanFaultInjector.checkpoint(.encoding)
        let canonicalBytes = try CanonicalRecordEncoder.encode(committedRecord)
        try saveSettingsPlanFaultInjector.checkpoint(.commitIntentConstruction)
        let intent = SettingsCommitIntent(commandID: context.commandID,
            expectedToken: token,
            committedRecord: committedRecord,
            canonicalBytes: canonicalBytes)
        observeSaveSettingsContext(context, consumer: .repositoryIntent)
        return SaveSettingsPlan(context: context,
            committedRecord: committedRecord,
            commitIntent: intent,
            targetViewState: target,
            targetTodayRecord: components.record,
            targetTodayRecoveryReason: components.recoveryReason,
            targetTodayToken: todayLoad.token,
            expectedStoreGeneration: stateGeneration,
            successEvent: successEvent)
    }

    private func publishCommittedSettings(plan: SaveSettingsPlan, result: SettingsCommitResult) {
        guard result.commandID == plan.context.commandID,
              result.record == plan.committedRecord,
              BusinessCommandResultGuard.accepts(
                commandID: result.commandID,
                expectedStoreGeneration: plan.expectedStoreGeneration,
                activeCommandID: activeCommandID,
                currentStoreGeneration: stateGeneration
              ) else {
            return
        }
        observeSaveSettingsContext(plan.context, consumer: .successPublication)
        settingsRecord = result.record
        settingsToken = .loaded(result.record.revision)
        notificationsEnabled = result.record.notificationsEnabled
        settingsDamage = nil
        todayRecord = plan.targetTodayRecord
        todayRecoveryReason = plan.targetTodayRecoveryReason
        todayToken = plan.targetTodayToken
        settingsReadErrorViewState = nil
        viewState = plan.targetViewState
        confirmation = nil
        scheduleTimeErrorViewState = nil
        feedback = plan.successEvent
        saveSettingsExecutionObserver.didPublishSuccess()
        stateGeneration &+= 1
    }

    private func buildStartTodayPlan(
        context: BusinessCommandContext
    ) async throws -> StartTodayPlan {
        try startTodayPreflightObserver.check(.commandContext, context: context)
        try startTodayPreflightObserver.check(.typedLoads, context: context)
        async let freshSettings = repository.loadSettingsForBusiness()
        async let freshToday = repository.loadTodayForBusiness()
        let (settingsLoad, todayLoad) = await (freshSettings, freshToday)
        guard settingsLoad.token == settingsToken else {
            let expected: RecordRevision?
            let actual: RecordRevision?
            if case let .loaded(revision) = settingsToken { expected = revision } else { expected = nil }
            if case let .loaded(revision) = settingsLoad.token { actual = revision } else { actual = nil }
            throw PersistenceError.revisionConflict(expected: expected, actual: actual)
        }
        guard todayLoad.token == todayToken else {
            throw Self.todayTokenConflict(expected: todayToken, actual: todayLoad.token)
        }
        let oldToday: TodayRecord
        switch todayLoad {
        case let .loaded(record, _): oldToday = record
        case .missing, .damaged:
            throw BusinessFailure.workdayTransition(.invalidWorkdayTransition)
        }
        guard oldToday.clockOutAtMs != nil else {
            throw BusinessFailure.workdayTransition(.incompletePreviousDay)
        }
        try startTodayPreflightObserver.check(.currentWorkday, context: context)
        let oldSnapshot = try workdayCalendar.todaySnapshot(from: oldToday)
        guard case let .valid(oldSettings) = oldSnapshot.settingsSnapshot else {
            throw BusinessFailure.workdayTransition(.invalidWorkdayTransition)
        }
        let oldKey = try WorkdayKey(validating: oldToday.dateKey)
        let snapshotCurrentKey = try workdayCalendar.dateKey(at: context.timestampMs,
            timeZoneIdentifier: oldSettings.timeZoneIdentifier)
        guard oldKey < snapshotCurrentKey, oldKey < context.commandDateKey else {
            throw BusinessFailure.workdayTransition(.invalidWorkdayTransition)
        }
        let target: BusinessViewState
        try startTodayPreflightObserver.check(.settingsClassification, context: context)
        switch settingsLoad {
        case let .damaged(damage, _): throw BusinessFailure.settingsRead(damage.issue)
        case .missing:
            try startTodayPreflightObserver.check(.targetViewState, context: context)
            target = try makeViewState(from: buildSnapshot(settings: nil,
                todayRecord: nil, todayRecoveryReason: nil, context: context),
                settingsAreDamaged: false)
        case let .loaded(settings, _):
            try startTodayPreflightObserver.check(.schedule, context: context)
            _ = try workdayCalendar.settingsSnapshot(from: settings,
                for: context.commandDateKey,
                timeZoneIdentifier: context.commandTimeZoneIdentifier)
            try startTodayPreflightObserver.check(.targetViewState, context: context)
            target = try makeViewState(from: buildSnapshot(settings: settings,
                todayRecord: nil, todayRecoveryReason: nil, context: context),
                settingsAreDamaged: false)
        }
        try startTodayPreflightObserver.check(.commitIntent, context: context)
        return StartTodayPlan(context: context,
            commitIntent: .init(commandID: context.commandID,
                expectedTodayRevision: oldToday.revision,
                expectedSettingsToken: settingsLoad.token),
            targetViewState: target)
    }

    private func clockIn(context: BusinessCommandContext) async throws -> BusinessCommandOutcome {
        try reconcile(context: context)
        guard viewState?.state == .ready, let settingsRecord else { return .rejected(.invalidState) }
        let settings = try workdayCalendar.settingsSnapshot(from: settingsRecord,
            for: context.commandDateKey,
            timeZoneIdentifier: context.commandTimeZoneIdentifier)
        guard context.timestampMs < settings.schedule.scheduledEndAt else {
            return .rejected(.clockInAfterScheduledEnd)
        }
        let proposed = try workdayCalendar.proposedToday(from: settingsRecord, context: context)
        let committed = try await repository.saveToday(proposed, expectedRevision: nil)
        todayRecord = committed
        todayToken = .loaded(committed.revision)
        todayRecoveryReason = nil
        confirmation = nil
        stateGeneration &+= 1
        try reconcile(context: context)
        await coordinateNotificationForToday(context: context, allowAdd: settingsRecord.notificationsEnabled)
        return .committed
    }

    private func requestClockOut(context: BusinessCommandContext) async throws -> BusinessCommandOutcome {
        try reconcile(context: context)
        switch viewState?.state {
        case .clockedInWaiting, .earning:
            guard let calculation = try earningsCalculation(at: context.timestampMs) else {
                return .rejected(.invalidState)
            }
            confirmation = .clockOut(.init(roundedEarnedCents: calculation.roundedEarnedCents,
                earnedDuration: calculation.earnedDuration, sampledAt: context.timestampMs))
            return .confirmationPresented
        case .awaitingClockOut:
            try await commitClockOut(context: context)
            feedback = .clockOutSucceeded
            return .committed
        default: return .rejected(.invalidState)
        }
    }

    private func commitClockOut(context: BusinessCommandContext) async throws {
        try reconcile(context: context)
        guard [.clockedInWaiting, .earning, .awaitingClockOut].contains(viewState?.state),
              let todayRecord else { throw BusinessFailure.invalidCalendar }
        let shouldCancelNotification = context.timestampMs < TimestampMilliseconds(
            rawValue: todayRecord.scheduledEndAtMs
        )
        let requestIdentifier = "workday-end-\(todayRecord.dateKey)"
        let proposed = TodayRecord(schemaVersion: TodayRecord.currentSchemaVersion,
            revision: todayRecord.revision, dateKey: todayRecord.dateKey,
            clockInAtMs: todayRecord.clockInAtMs,
            clockOutAtMs: context.timestampMs.rawValue,
            settingsSnapshot: todayRecord.settingsSnapshot,
            scheduledStartAtMs: todayRecord.scheduledStartAtMs,
            scheduledEndAtMs: todayRecord.scheduledEndAtMs,
            notificationScheduledDateKey: todayRecord.notificationScheduledDateKey,
            notificationRequestIdentifier: todayRecord.notificationRequestIdentifier,
            updatedAtMs: context.timestampMs.rawValue)
        let committed = try await repository.saveToday(proposed, expectedRevision: todayRecord.revision)
        self.todayRecord = committed
        todayToken = .loaded(committed.revision)
        confirmation = nil
        stateGeneration &+= 1
        try reconcile(context: context)
        if shouldCancelNotification {
            await cancelNotification(identifier: requestIdentifier)
        }
    }

    private func resetDamagedSettings(context: BusinessCommandContext) async throws {
        let token = settingsToken
        let target = try makeViewState(from: buildSnapshot(settings: nil,
            todayRecord: todayRecord, todayRecoveryReason: todayRecoveryReason, context: context),
            settingsAreDamaged: false)
        try await repository.resetDamagedSettingsToMissing(expectedToken: token)
        settingsRecord = nil
        settingsToken = .missing
        settingsDamage = nil
        settingsReadErrorViewState = nil
        viewState = target
        confirmation = nil
        scheduleTimeErrorViewState = nil
        feedback = .settingsResetSucceeded
        stateGeneration &+= 1
    }

    private func resetToday(
        context: BusinessCommandContext
    ) async throws -> BusinessCommandOutcome {
        // Reset is the user's explicit destructive recovery action. The CAS delete is
        // the linearization point; schedule derivation for the remaining Settings is
        // deliberately post-delete and can only choose the recovery surface.
        confirmation = nil
        try await repository.resetToday(expectedToken: todayToken)
        todayRecord = nil
        todayRecoveryReason = nil
        todayToken = .missing
        stateGeneration &+= 1
        do {
            try reconcile(context: context)
        } catch let error as ScheduleTimeError {
            publishActiveScheduleError(error)
        } catch let error as EarningsCalculationError {
            publishRestoreFailure(.calculation(error))
        } catch {
            publishRestoreFailure(.invalidCalendar)
        }
        feedback = .todayResetSucceeded
        return .committed
    }

    private func reconcile(context: BusinessCommandContext) throws {
        saveSettingsExecutionObserver.willReconcile()
        if settingsDamage != nil, todayRecord == nil, todayRecoveryReason == nil {
            viewState = nil
            publishSettingsError()
            // Maintenance must preserve the explicit recovery decision while
            // damaged Settings legitimately prevent a business ViewState.
            if confirmation != .resetSettings { confirmation = nil }
            if scheduleTimeErrorViewState?.context != .proposedSettings {
                scheduleTimeErrorViewState = nil
            }
            return
        }
        let snapshot = try buildSnapshot(settings: settingsRecord,
            todayRecord: todayRecord,
            todayRecoveryReason: todayRecoveryReason,
            context: context)
        viewState = try makeViewState(from: snapshot)
        try refreshClockOutConfirmation(from: snapshot)
        // A presentation refresh validates committed records, not the user's
        // rejected draft. Keep its inline error until a command result clears it.
        if scheduleTimeErrorViewState?.context != .proposedSettings {
            scheduleTimeErrorViewState = nil
        }
        publishSettingsError()
    }

    private func buildSnapshot(settings: SettingsRecord?,
                               todayRecord: TodayRecord?,
                               todayRecoveryReason: RecoveryReason?,
                               context: BusinessCommandContext,
                               beforeStateDerivation: (() -> Void)? = nil) throws -> DerivedSnapshot {
        let todaySnapshot: TodayRecordSnapshot?
        let todaySource: TodayRecordSource
        if let todayRecoveryReason {
            todaySnapshot = nil
            todaySource = .corrupted(todayRecoveryReason)
        } else if let todayRecord {
            let mapped = try workdayCalendar.todaySnapshot(from: todayRecord)
            todaySnapshot = mapped
            todaySource = .decoded(mapped)
        } else {
            todaySnapshot = nil
            todaySource = .absent
        }
        let currentDateKey: WorkdayKey
        if let zone = todaySnapshot?.settingsSnapshot.validValue?.timeZoneIdentifier {
            currentDateKey = try workdayCalendar.dateKey(
                at: context.timestampMs,
                timeZoneIdentifier: zone
            )
        } else {
            currentDateKey = context.commandDateKey
        }
        let currentSettings: WorkdaySettingsSnapshot?
        if case .absent = todaySource, let settings {
            currentSettings = try workdayCalendar.settingsSnapshot(from: settings,
                for: currentDateKey,
                timeZoneIdentifier: context.commandTimeZoneIdentifier)
        } else { currentSettings = nil }
        beforeStateDerivation?()
        let result = StateDeriver.derive(context: .init(currentDateKey: currentDateKey,
            currentSettings: currentSettings, today: todaySource), now: context.timestampMs)
        return .init(result: result, currentDateKey: currentDateKey,
            currentSettings: currentSettings, today: todaySnapshot, now: context.timestampMs)
    }

    private func makeViewState(
        from snapshot: DerivedSnapshot,
        settingsAreDamaged: Bool? = nil,
        beforeAmountAndTimeDerivation: (() throws -> Void)? = nil,
        beforeEarningsCalculatorInvocation: (() -> Void)? = nil,
        beforeViewStateConstruction: (() throws -> Void)? = nil
    ) throws -> BusinessViewState {
        let settingsDamageActive = settingsAreDamaged ?? (settingsDamage != nil)
        try beforeAmountAndTimeDerivation?()
        let zeroLive = try LiveEarnedMilliYuan(validating: 0)
        let zeroRounded = try RoundedEarnedCents(validating: 0)
        let calculation = try earningsCalculation(today: snapshot.today,
            at: snapshot.now,
            state: snapshot.result.state,
            beforeCalculatorInvocation: beforeEarningsCalculatorInvocation)
        let amount: BusinessEarnedAmount
        switch snapshot.result.state {
        case .unconfigured, .ready: amount = .rounded(zeroRounded)
        case .clockedInWaiting: amount = .live(zeroLive)
        case .earning: amount = .live(calculation?.liveEarnedMilliYuan ?? zeroLive)
        case .awaitingClockOut, .completed: amount = .rounded(calculation?.roundedEarnedCents ?? zeroRounded)
        case .recoveryRequired: amount = .hidden
        }
        let metricsSettings: WorkdaySettingsSnapshot?
        switch snapshot.result.state {
        case .ready: metricsSettings = snapshot.currentSettings
        case .clockedInWaiting, .earning, .awaitingClockOut:
            metricsSettings = snapshot.today?.settingsSnapshot.validValue
        case .unconfigured, .completed, .recoveryRequired: metricsSettings = nil
        }
        let timing = try metricsSettings.map {
            try ScheduleTimingCalculator.calculate(schedule: $0.schedule, now: snapshot.now)
        }
        let todayTimeZoneIdentifier = snapshot.today?.settingsSnapshot.validValue?.timeZoneIdentifier
        let isPreviousWorkday: Bool
        if let today = snapshot.today,
           let key = try? WorkdayKey(validating: today.dateKey) {
            isPreviousWorkday = key < snapshot.currentDateKey
        } else {
            isPreviousWorkday = false
        }
        let clockOutDateKey: String?
        if let clockOut = snapshot.today?.clockOutAt,
           let todayTimeZoneIdentifier {
            clockOutDateKey = try workdayCalendar.dateKey(
                at: clockOut,
                timeZoneIdentifier: todayTimeZoneIdentifier
            ).rawValue
        } else {
            clockOutDateKey = nil
        }
        try beforeViewStateConstruction?()
        return BusinessViewState(state: snapshot.result.state,
            recoveryReason: snapshot.result.recoveryReason,
            amount: amount,
            earnedDuration: calculation?.earnedDuration,
            scheduledProgress: timing?.scheduledProgress,
            remainingToStart: timing?.remainingToStart,
            remainingToEnd: timing?.remainingToEnd,
            clockInAt: snapshot.today?.clockInAt,
            clockOutAt: snapshot.today?.clockOutAt,
            todayDateKey: snapshot.today?.dateKey,
            todayTimeZoneIdentifier: todayTimeZoneIdentifier,
            isPreviousWorkday: isPreviousWorkday,
            clockOutDateKey: clockOutDateKey,
            canClockIn: snapshot.result.state == .ready
                && snapshot.currentSettings.map { snapshot.now < $0.schedule.scheduledEndAt } == true,
            canRequestClockOut: [.clockedInWaiting, .earning, .awaitingClockOut].contains(snapshot.result.state),
            canRequestTodayReset: snapshot.result.state == .recoveryRequired,
            canRequestStartToday: snapshot.result.state == .completed
                && isPreviousWorkday
                && !settingsDamageActive,
            canRequestSettingsReset: settingsDamageActive,
            previousDayCleanupPending: false)
    }

    private func earningsCalculation(at now: TimestampMilliseconds) throws -> EarningsCalculationResult? {
        try earningsCalculation(today: try todayRecord.map(workdayCalendar.todaySnapshot(from:)),
            at: now, state: viewState?.state)
    }

    private func earningsCalculation(today: TodayRecordSnapshot?,
                                     at now: TimestampMilliseconds,
                                     state: WorkdayState?,
                                     beforeCalculatorInvocation: (() -> Void)? = nil)
        throws -> EarningsCalculationResult?
    {
        guard state != .recoveryRequired, let today, let clockInAt = today.clockInAt,
              case let .valid(settings) = today.settingsSnapshot else { return nil }
        beforeCalculatorInvocation?()
        return try EarningsCalculator.calculate(.init(settings: settings,
            clockInAt: clockInAt, clockOutAt: today.clockOutAt, now: now))
    }

    private func commitSettingsFlag(
        context: BusinessCommandContext,
        transform: (SettingsRecord) -> SettingsRecord
    ) async throws {
        async let freshSettings = repository.loadSettingsForBusiness()
        async let freshToday = repository.loadTodayForBusiness()
        let (settingsLoad, todayLoad) = await (freshSettings, freshToday)
        guard settingsLoad.token == settingsToken else {
            throw PersistenceError.revisionConflict(expected: settingsRecord?.revision, actual: nil)
        }
        guard todayLoad.token == todayToken else {
            throw Self.todayTokenConflict(expected: todayToken, actual: todayLoad.token)
        }
        guard case let .loaded(current, _) = settingsLoad else {
            throw BusinessFailure.settingsRead(.readFailed)
        }
        let proposed = transform(current)
        let committedRecord = proposed.replacingRevision(try current.revision.next())
        try committedRecord.validated()

        let components = Self.todayComponents(todayLoad)
        let snapshot = try buildSnapshot(
            settings: committedRecord,
            todayRecord: components.record,
            todayRecoveryReason: components.recoveryReason,
            context: context
        )
        let target = try makeViewState(from: snapshot, settingsAreDamaged: false)
        let canonicalBytes = try CanonicalRecordEncoder.encode(committedRecord)
        let plan = SaveSettingsPlan(
            context: context,
            committedRecord: committedRecord,
            commitIntent: .init(
                commandID: context.commandID,
                expectedToken: settingsToken,
                committedRecord: committedRecord,
                canonicalBytes: canonicalBytes
            ),
            targetViewState: target,
            targetTodayRecord: components.record,
            targetTodayRecoveryReason: components.recoveryReason,
            targetTodayToken: todayLoad.token,
            expectedStoreGeneration: stateGeneration,
            successEvent: .settingsSaved(.init(
                context: context,
                committedRevision: committedRecord.revision
            ))
        )

        activeCommandID = context.commandID
        defer {
            if activeCommandID == context.commandID { activeCommandID = nil }
        }
        let result = try await repository.commitSaveSettings(plan.commitIntent)
        publishCommittedSettings(plan: plan, result: result)
    }

    private func coordinateNotificationForToday(
        context: BusinessCommandContext,
        allowAdd: Bool
    ) async {
        guard let todayRecord,
              todayRecord.clockOutAtMs == nil,
              context.timestampMs.rawValue < todayRecord.scheduledEndAtMs else {
            return
        }
        let identifier = "workday-end-\(todayRecord.dateKey)"

        let pending: Set<String>
        do {
            pending = try await notificationService.pendingRequestIdentifiers()
        } catch {
            recordNotificationDiagnostic(.scheduling(.pendingQueryFailed, identifier: identifier))
            return
        }

        if pending.contains(identifier) {
            await persistNotificationMarker(identifier: identifier, context: context)
            return
        }
        guard allowAdd else { return }

        let request = WorkdayEndNotificationRequest(
            identifier: identifier,
            scheduledAt: TimestampMilliseconds(rawValue: todayRecord.scheduledEndAtMs),
            timeZoneIdentifier: todayRecord.settingsSnapshot.timeZoneIdentifier
        )
        do {
            try await notificationService.add(request)
        } catch {
            recordNotificationDiagnostic(.scheduling(.addFailed, identifier: identifier))
            notificationPreferenceError = .addFailed
            return
        }
        do {
            let confirmed = try await notificationService.pendingRequestIdentifiers()
            guard confirmed.contains(identifier) else {
                recordNotificationDiagnostic(.scheduling(.addNotConfirmed, identifier: identifier))
                notificationPreferenceError = .addNotConfirmed
                return
            }
        } catch {
            recordNotificationDiagnostic(.scheduling(.pendingQueryFailed, identifier: identifier))
            notificationPreferenceError = .pendingQueryFailed
            return
        }
        await persistNotificationMarker(identifier: identifier, context: context)
    }

    private func persistNotificationMarker(
        identifier: String,
        context: BusinessCommandContext
    ) async {
        guard let current = todayRecord,
              current.notificationRequestIdentifier == nil,
              current.notificationScheduledDateKey == nil else { return }
        let proposed = TodayRecord(
            schemaVersion: TodayRecord.currentSchemaVersion,
            revision: current.revision,
            dateKey: current.dateKey,
            clockInAtMs: current.clockInAtMs,
            clockOutAtMs: current.clockOutAtMs,
            settingsSnapshot: current.settingsSnapshot,
            scheduledStartAtMs: current.scheduledStartAtMs,
            scheduledEndAtMs: current.scheduledEndAtMs,
            notificationScheduledDateKey: current.dateKey,
            notificationRequestIdentifier: identifier,
            updatedAtMs: context.timestampMs.rawValue
        )
        do {
            let committed = try await repository.saveToday(
                proposed,
                expectedRevision: current.revision
            )
            todayRecord = committed
            todayToken = .loaded(committed.revision)
            stateGeneration &+= 1
        } catch {
            recordNotificationDiagnostic(.scheduling(.markerPersistenceFailed, identifier: identifier))
            notificationPreferenceError = .markerPersistenceFailed
        }
    }

    private func cancelNotification(identifier: String) async {
        do {
            try await notificationService.removePendingRequest(identifier: identifier)
        } catch {
            publishNotificationCancellationFailure(.cancellationFailed, identifier: identifier)
            return
        }
        let pending: Set<String>
        do {
            pending = try await notificationService.pendingRequestIdentifiers()
        } catch {
            publishNotificationCancellationFailure(
                .cancellationPendingQueryFailed,
                identifier: identifier
            )
            return
        }
        guard !pending.contains(identifier) else {
            publishNotificationCancellationFailure(.cancellationNotConfirmed, identifier: identifier)
            return
        }
    }

    private func publishNotificationCancellationFailure(
        _ error: NotificationFeatureError,
        identifier: String
    ) {
        recordNotificationDiagnostic(.cancellation(error, identifier: identifier))
        notificationPreferenceError = error
    }

    private func recordNotificationDiagnostic(_ event: NotificationDiagnosticEvent) {
        notificationDiagnostics.append(event)
    }

    private func applySettingsLoad(_ result: SettingsTypedLoadResult) {
        settingsToken = result.token
        switch result {
        case .missing:
            settingsRecord = nil; settingsDamage = nil; notificationsEnabled = false
        case let .loaded(record, _):
            settingsRecord = record; settingsDamage = nil
            notificationsEnabled = record.notificationsEnabled
        case let .damaged(damage, _):
            settingsRecord = nil; settingsDamage = damage.issue; notificationsEnabled = false
        }
    }

    private func applyTodayLoad(_ result: TodayTypedLoadResult) {
        let components = Self.todayComponents(result)
        todayToken = result.token
        todayRecord = components.record
        todayRecoveryReason = components.recoveryReason
    }

    private static func todayComponents(_ result: TodayTypedLoadResult)
        -> (record: TodayRecord?, recoveryReason: RecoveryReason?) {
        switch result {
        case .missing: return (nil, nil)
        case let .loaded(record, _): return (record, nil)
        case let .damaged(damage, _): return (nil, recoveryReason(for: damage.issue))
        }
    }

    private static func recoveryReason(for issue: RecordDamageIssue) -> RecoveryReason {
        switch issue {
        case .unsupportedSchemaVersion: return .unsupportedTodaySchema
        default: return .unreadableTodayRecord
        }
    }

    private static func todayTokenConflict(
        expected: TodayRecordToken,
        actual: TodayRecordToken
    ) -> PersistenceError {
        let expectedRevision: RecordRevision?
        let actualRevision: RecordRevision?
        if case let .loaded(revision) = expected { expectedRevision = revision }
        else { expectedRevision = nil }
        if case let .loaded(revision) = actual { actualRevision = revision }
        else { actualRevision = nil }
        return .revisionConflict(expected: expectedRevision, actual: actualRevision)
    }

    private func refreshClockOutConfirmation(from snapshot: DerivedSnapshot) throws {
        guard case .clockOut = confirmation,
              [.clockedInWaiting, .earning, .awaitingClockOut].contains(snapshot.result.state),
              let calculation = try earningsCalculation(today: snapshot.today,
                at: snapshot.now, state: snapshot.result.state) else { return }
        confirmation = .clockOut(.init(roundedEarnedCents: calculation.roundedEarnedCents,
            earnedDuration: calculation.earnedDuration, sampledAt: snapshot.now))
    }

    private func publishSettingsError() {
        guard let settingsDamage else { settingsReadErrorViewState = nil; return }
        settingsReadErrorViewState = .init(issue: settingsDamage,
            isBlocking: todayRecord == nil && todayRecoveryReason == nil)
        feedback = .settingsRecoveryRequired(settingsDamage)
    }

    private func publishActiveScheduleError(_ error: ScheduleTimeError,
                                            preservingProposedSettingsError: Bool = false) {
        viewState = nil
        confirmation = nil
        feedback = nil
        // A failed render/maintenance refresh still blocks business state, but
        // must not replace the rejected draft's command-bound field diagnostic.
        // Explicit restore/reset callers retain their original publication path.
        if !preservingProposedSettingsError || scheduleTimeErrorViewState?.context != .proposedSettings {
            scheduleTimeErrorViewState = .init(error: error, context: .activeSchedule)
        }
    }

    private func publishRestoreFailure(_ failure: BusinessFailure) {
        viewState = nil
        confirmation = nil
        scheduleTimeErrorViewState = nil
        feedback = .restoreFailed(failure)
    }

    private func publishCommandFailureIfCurrent(
        _ failure: BusinessFailure,
        command: BusinessCommand,
        commandID: UUID,
        expectedStoreGeneration: UInt64
    ) {
        if case .saveWorkRules = command {
            guard BusinessCommandResultGuard.accepts(
                commandID: commandID,
                expectedStoreGeneration: expectedStoreGeneration,
                activeCommandID: activeCommandID,
                currentStoreGeneration: stateGeneration
            ) else { return }
        }
        feedback = .commandFailed(command.kind, failure)
    }

    private func commandContext(commandID: UUID) throws -> BusinessCommandContext {
        let now = nowProvider.nowMilliseconds()
        let timeZoneIdentifier = timeZoneIdentifierProvider.currentIdentifier()
        return BusinessCommandContext(commandID: commandID,
            timestampMs: now,
            commandTimeZoneIdentifier: timeZoneIdentifier,
            commandDateKey: try workdayCalendar.dateKey(
                at: now,
                timeZoneIdentifier: timeZoneIdentifier
            ))
    }

    private func setCommandPhase(_ phase: BusinessCommandPhase) {
        commandPhase = phase
        commandPhaseHistory.append(phase)
    }

    private static func settings(applying input: WorkRuleSettingsInput,
                                 to current: SettingsRecord?,
                                 updatedAt: Int64) -> SettingsRecord {
        SettingsRecord(schemaVersion: SettingsRecord.currentSchemaVersion,
            revision: current?.revision ?? .proposed,
            dailyWageCents: input.dailyWageCents,
            workStartMinuteOfDay: input.workStartMinuteOfDay,
            workEndMinuteOfDay: input.workEndMinuteOfDay,
            notificationsEnabled: current?.notificationsEnabled ?? false,
            alwaysOnTop: current?.alwaysOnTop ?? true,
            lockPanelPosition: current?.lockPanelPosition ?? false,
            hideInFullScreen: current?.hideInFullScreen ?? true,
            launchAtLogin: current?.launchAtLogin ?? false,
            panelVisible: current?.panelVisible ?? true,
            panelPlacement: current?.panelPlacement,
            updatedAtMs: updatedAt)
    }

    private static func validateSettingsInput(_ input: WorkRuleSettingsInput) throws {
        _ = try DailyWageCents(validating: input.dailyWageCents)
        guard (0...1439).contains(input.workStartMinuteOfDay),
              (0...1439).contains(input.workEndMinuteOfDay),
              input.workEndMinuteOfDay > input.workStartMinuteOfDay else {
            throw RecordValidationError.invalidWorkMinutes
        }
    }

    private static func settings(
        _ current: SettingsRecord,
        notificationsEnabled: Bool,
        updatedAt: Int64
    ) -> SettingsRecord {
        SettingsRecord(
            schemaVersion: SettingsRecord.currentSchemaVersion,
            revision: current.revision,
            dailyWageCents: current.dailyWageCents,
            workStartMinuteOfDay: current.workStartMinuteOfDay,
            workEndMinuteOfDay: current.workEndMinuteOfDay,
            notificationsEnabled: notificationsEnabled,
            alwaysOnTop: current.alwaysOnTop,
            lockPanelPosition: current.lockPanelPosition,
            hideInFullScreen: current.hideInFullScreen,
            launchAtLogin: current.launchAtLogin,
            panelVisible: current.panelVisible,
            panelPlacement: current.panelPlacement,
            updatedAtMs: updatedAt
        )
    }

    private static func settings(
        _ current: SettingsRecord,
        launchAtLogin: Bool,
        updatedAt: Int64
    ) -> SettingsRecord {
        SettingsRecord(
            schemaVersion: SettingsRecord.currentSchemaVersion,
            revision: current.revision,
            dailyWageCents: current.dailyWageCents,
            workStartMinuteOfDay: current.workStartMinuteOfDay,
            workEndMinuteOfDay: current.workEndMinuteOfDay,
            notificationsEnabled: current.notificationsEnabled,
            alwaysOnTop: current.alwaysOnTop,
            lockPanelPosition: current.lockPanelPosition,
            hideInFullScreen: current.hideInFullScreen,
            launchAtLogin: launchAtLogin,
            panelVisible: current.panelVisible,
            panelPlacement: current.panelPlacement,
            updatedAtMs: updatedAt
        )
    }
}

private extension SettingsSnapshotSource {
    var validValue: WorkdaySettingsSnapshot? {
        guard case let .valid(value) = self else { return nil }
        return value
    }
}
