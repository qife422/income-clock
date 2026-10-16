import Foundation
import XCTest
@testable import IncomeClock

final class PersistenceRecordsTests: XCTestCase {
    func testRevisionUsesJSONSafeDecimalStringAndSupportsUInt64Maximum() throws {
        let revision = RecordRevision(rawValue: UInt64.max)
        let data = try JSONEncoder().encode(revision)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"18446744073709551615\"")
        XCTAssertEqual(try JSONDecoder().decode(RecordRevision.self, from: data), revision)
        XCTAssertThrowsError(try revision.next()) { error in
            XCTAssertEqual(error as? PersistenceError, .revisionOverflow)
        }
    }

    func testAllThreeProposedRecordsBecomeValidAtCommittedRevision() throws {
        let revision = RecordRevision(rawValue: 1)
        let settings = PersistenceTestSupport.proposedSettings().replacingRevision(revision)
        let today = PersistenceTestSupport.proposedToday().replacingRevision(revision)
        let theme = PersistenceTestSupport.proposedThemePreferences().replacingRevision(revision)

        XCTAssertNoThrow(try settings.validated())
        XCTAssertNoThrow(try today.validated())
        XCTAssertNoThrow(try theme.validated())
    }

    func testThemeIDValidationMatchesProductContractBoundaries() throws {
        for themeID in ["a", "com.example.cat-worker", String(repeating: "a", count: 255)] {
            XCTAssertNoThrow(
                try themePreferences(themeID: themeID).validated(),
                "Expected valid theme ID: \(themeID)"
            )
        }

        for themeID in [
            ".a", "a.", "a..b", "a.-b", "a-.b", "a--b", "A.b", "a_b", "猫.theme",
            String(repeating: "a", count: 256)
        ] {
            XCTAssertThrowsError(
                try themePreferences(themeID: themeID).validated(),
                "Expected invalid theme ID: \(themeID)"
            ) { error in
                XCTAssertEqual(error as? RecordValidationError, .invalidThemeID)
            }
        }
    }

    func testTodaySemanticValidationRejectsBoundaryAndNotificationCorruption() throws {
        let valid = PersistenceTestSupport.proposedToday().replacingRevision(.init(rawValue: 1))
        let invalidBoundary = TodayRecord(
            schemaVersion: valid.schemaVersion,
            revision: valid.revision,
            dateKey: valid.dateKey,
            clockInAtMs: valid.clockInAtMs,
            clockOutAtMs: valid.clockOutAtMs,
            settingsSnapshot: valid.settingsSnapshot,
            scheduledStartAtMs: valid.scheduledStartAtMs + 1,
            scheduledEndAtMs: valid.scheduledEndAtMs,
            notificationScheduledDateKey: valid.notificationScheduledDateKey,
            notificationRequestIdentifier: valid.notificationRequestIdentifier,
            updatedAtMs: valid.updatedAtMs
        )
        let invalidMarker = TodayRecord(
            schemaVersion: valid.schemaVersion,
            revision: valid.revision,
            dateKey: valid.dateKey,
            clockInAtMs: valid.clockInAtMs,
            clockOutAtMs: valid.clockOutAtMs,
            settingsSnapshot: valid.settingsSnapshot,
            scheduledStartAtMs: valid.scheduledStartAtMs,
            scheduledEndAtMs: valid.scheduledEndAtMs,
            notificationScheduledDateKey: valid.dateKey,
            notificationRequestIdentifier: nil,
            updatedAtMs: valid.updatedAtMs
        )

        XCTAssertThrowsError(try invalidBoundary.validated()) { error in
            XCTAssertEqual(error as? RecordValidationError, .snapshotBoundaryMismatch)
        }
        XCTAssertThrowsError(try invalidMarker.validated()) { error in
            XCTAssertEqual(error as? RecordValidationError, .invalidNotificationMarker)
        }
    }

    func testTodayValidationAllowsNextDayAndMultiDayClockOut() throws {
        let base = PersistenceTestSupport.proposedToday().replacingRevision(.init(rawValue: 1))
        for day in [14, 18] {
            let record = TodayRecord(
                schemaVersion: base.schemaVersion,
                revision: base.revision,
                dateKey: base.dateKey,
                clockInAtMs: base.clockInAtMs,
                clockOutAtMs: PersistenceTestSupport.milliseconds(
                    year: 2026, month: 8, day: day, hour: 8
                ),
                settingsSnapshot: base.settingsSnapshot,
                scheduledStartAtMs: base.scheduledStartAtMs,
                scheduledEndAtMs: base.scheduledEndAtMs,
                notificationScheduledDateKey: base.notificationScheduledDateKey,
                notificationRequestIdentifier: base.notificationRequestIdentifier,
                updatedAtMs: base.updatedAtMs
            )
            XCTAssertNoThrow(try record.validated())
        }
    }

    private func themePreferences(themeID: String) -> ThemePreferencesRecord {
        ThemePreferencesRecord(
            schemaVersion: ThemePreferencesRecord.currentSchemaVersion,
            revision: RecordRevision(rawValue: 1),
            selectedThemeId: themeID,
            preferredThemeAppearance: .system,
            themeSoundsEnabled: false,
            updatedAtMs: 1
        )
    }
}
