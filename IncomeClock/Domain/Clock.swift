import Foundation

protocol NowProvider: Sendable {
    func nowMilliseconds() -> TimestampMilliseconds
}

struct SystemClock: NowProvider {
    func nowMilliseconds() -> TimestampMilliseconds {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        return TimestampMilliseconds(rawValue: Int64(milliseconds.rounded(.towardZero)))
    }
}

struct FixedClock: NowProvider {
    let instant: TimestampMilliseconds

    func nowMilliseconds() -> TimestampMilliseconds {
        instant
    }
}

protocol TimeZoneIdentifierProvider: Sendable {
    func currentIdentifier() -> String
}

struct SystemTimeZoneIdentifierProvider: TimeZoneIdentifierProvider {
    func currentIdentifier() -> String { TimeZone.current.identifier }
}

struct FixedTimeZoneIdentifierProvider: TimeZoneIdentifierProvider {
    let identifier: String

    func currentIdentifier() -> String { identifier }
}

#if DEBUG
/// Debug-only authoritative wall time, advanced by a monotonic clock rather than frame count.
struct AdvancingClock: NowProvider {
    let origin: TimestampMilliseconds
    let rate: Double
    private let startedAt = ProcessInfo.processInfo.systemUptime
    func nowMilliseconds() -> TimestampMilliseconds {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000 * rate
        let proposed = Double(origin.rawValue) + elapsed
        guard proposed.isFinite, proposed < Double(Int64.max), proposed >= Double(Int64.min) else {
            return origin
        }
        return .init(rawValue: Int64(proposed.rounded(.towardZero)))
    }
}
#endif
