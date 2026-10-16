import Foundation

struct EarningsCalculationInput: Equatable, Sendable {
    let settings: WorkdaySettingsSnapshot
    let clockInAt: TimestampMilliseconds
    let clockOutAt: TimestampMilliseconds?
    let now: TimestampMilliseconds
}

struct EarningsCalculationResult: Equatable, Sendable {
    let effectiveStartAt: TimestampMilliseconds
    let effectiveEndAt: TimestampMilliseconds
    let earnedDuration: DurationMilliseconds
    let exactEarnedCents: RationalCents
    let liveEarnedMilliYuan: LiveEarnedMilliYuan
    let roundedEarnedCents: RoundedEarnedCents
    let scheduledProgress: Double
    let remainingToStart: DurationMilliseconds
    let remainingToEnd: DurationMilliseconds
}

struct ScheduleTimingResult: Equatable, Sendable {
    let scheduledProgress: Double
    let remainingToStart: DurationMilliseconds
    let remainingToEnd: DurationMilliseconds
}

enum EarningsCalculationError: Error, Equatable, Sendable {
    case clockInAfterScheduledEnd
    case clockOutBeforeClockIn
    case timestampOutsideWorkday
    case arithmeticOverflow
}

enum EarningsCalculator {
    static func calculate(_ input: EarningsCalculationInput) throws -> EarningsCalculationResult {
        let schedule = input.settings.schedule

        guard input.clockInAt <= schedule.scheduledEndAt else {
            throw EarningsCalculationError.clockInAfterScheduledEnd
        }
        guard schedule.contains(input.clockInAt) else {
            throw EarningsCalculationError.timestampOutsideWorkday
        }
        if let clockOutAt = input.clockOutAt, clockOutAt < input.clockInAt {
            throw EarningsCalculationError.clockOutBeforeClockIn
        }

        do {
            let scheduledDuration = try schedule.scheduledDuration
            let effectiveStartAt = max(input.clockInAt, schedule.scheduledStartAt)
            let effectiveEndAt = min(input.clockOutAt ?? input.now, schedule.scheduledEndAt)

            let earnedDuration: DurationMilliseconds
            if effectiveEndAt <= effectiveStartAt {
                earnedDuration = .zero
            } else {
                earnedDuration = try DurationMilliseconds(
                    validating: CheckedInteger.subtract(effectiveEndAt.rawValue, effectiveStartAt.rawValue)
                )
            }

            let exactNumerator = try CheckedInteger.multiply(
                input.settings.dailyWage.rawValue,
                earnedDuration.rawValue
            )
            let exactEarnedCents = try RationalCents(
                numerator: exactNumerator,
                denominator: scheduledDuration.rawValue
            )
            let liveNumerator = try CheckedInteger.multiply(exactNumerator, 10)
            let liveRational = try RationalCents(
                numerator: liveNumerator,
                denominator: scheduledDuration.rawValue
            )

            let liveEarnedMilliYuan = try LiveEarnedMilliYuan(
                validating: liveRational.roundedHalfUp()
            )
            let roundedEarnedCents = try RoundedEarnedCents(
                validating: exactEarnedCents.roundedHalfUp()
            )

            let timing = try ScheduleTimingCalculator.calculate(
                schedule: schedule,
                now: input.now
            )
            return EarningsCalculationResult(
                effectiveStartAt: effectiveStartAt,
                effectiveEndAt: effectiveEndAt,
                earnedDuration: earnedDuration,
                exactEarnedCents: exactEarnedCents,
                liveEarnedMilliYuan: liveEarnedMilliYuan,
                roundedEarnedCents: roundedEarnedCents,
                scheduledProgress: timing.scheduledProgress,
                remainingToStart: timing.remainingToStart,
                remainingToEnd: timing.remainingToEnd
            )
        } catch DomainValidationError.arithmeticOverflow {
            throw EarningsCalculationError.arithmeticOverflow
        }
    }

}

enum ScheduleTimingCalculator {
    static func calculate(
        schedule: WorkdaySchedule,
        now: TimestampMilliseconds
    ) throws -> ScheduleTimingResult {
        ScheduleTimingResult(
            scheduledProgress: try scheduledProgress(now: now, schedule: schedule),
            remainingToStart: try remaining(from: now, until: schedule.scheduledStartAt),
            remainingToEnd: try remaining(from: now, until: schedule.scheduledEndAt)
        )
    }

    private static func scheduledProgress(
        now: TimestampMilliseconds,
        schedule: WorkdaySchedule
    ) throws -> Double {
        if now <= schedule.scheduledStartAt { return 0 }
        if now >= schedule.scheduledEndAt { return 1 }

        do {
            let elapsed = try CheckedInteger.subtract(now.rawValue, schedule.scheduledStartAt.rawValue)
            let duration = try schedule.scheduledDuration.rawValue
            return Double(elapsed) / Double(duration)
        } catch DomainValidationError.arithmeticOverflow {
            throw EarningsCalculationError.arithmeticOverflow
        }
    }

    private static func remaining(
        from now: TimestampMilliseconds,
        until boundary: TimestampMilliseconds
    ) throws -> DurationMilliseconds {
        guard now < boundary else { return .zero }
        do {
            return try DurationMilliseconds(
                validating: CheckedInteger.subtract(boundary.rawValue, now.rawValue)
            )
        } catch DomainValidationError.arithmeticOverflow {
            throw EarningsCalculationError.arithmeticOverflow
        }
    }
}
