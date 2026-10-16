import XCTest
@testable import IncomeClock

final class ClockTests: XCTestCase {
    func testFixedClockAlwaysReturnsTheInjectedInstant() {
        let expected = TimestampMilliseconds(rawValue: 1_786_579_200_123)
        let clock = FixedClock(instant: expected)

        XCTAssertEqual(clock.nowMilliseconds(), expected)
        XCTAssertEqual(clock.nowMilliseconds(), expected)
    }

    func testSystemClockReturnsUnixMillisecondsNearCurrentDate() {
        let before = Int64(Date().timeIntervalSince1970 * 1_000)
        let actual = SystemClock().nowMilliseconds().rawValue
        let after = Int64(Date().timeIntervalSince1970 * 1_000)

        XCTAssertGreaterThanOrEqual(actual, before)
        XCTAssertLessThanOrEqual(actual, after)
    }
}
