import AppKit
import SwiftUI
import XCTest
@testable import IncomeClock

private struct PendingSoundCatalog: ThemeCatalogProviding {
    let theme: ValidatedTheme
    func loadBuiltInThemes() async -> ThemeCatalogSnapshot { .init(themes: [theme], diagnostics: []) }
}

private actor AppearanceCommitGate: ThemePreferencesRepository {
    private var record: ThemePreferencesRecord
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var saveCount = 0
    private let failFirst: Bool
    init(record: ThemePreferencesRecord, failFirst: Bool) { self.record = record; self.failFirst = failFirst }
    func loadThemePreferences() -> RecordLoadResult<ThemePreferencesRecord> { .loaded(record, migration: .current) }
    func waitUntilSaving() async {
        while continuation == nil { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
    func saveThemePreferences(_ proposed: ThemePreferencesRecord, expectedRevision: RecordRevision?) async throws -> ThemePreferencesRecord {
        saveCount += 1
        if saveCount == 1 {
            await withCheckedContinuation { continuation = $0 }
            if failFirst { throw PersistenceError.atomicWriteFailed }
        }
        guard record.revision == expectedRevision else {
            throw PersistenceError.revisionConflict(expected: expectedRevision, actual: record.revision)
        }
        record = proposed.replacingRevision(.init(rawValue: record.revision.rawValue + 1))
        return record
    }
    func recoverThemePreferences(_ proposed: ThemePreferencesRecord) async throws -> ThemePreferencesRecord {
        throw PersistenceError.atomicWriteFailed
    }
}

@MainActor
private final class PendingSoundPlayer: ThemeSoundPlaying {
    private(set) var bytes: [Data] = []
    private var completion: (@MainActor (Bool) -> Void)?
    func play(_ data: Data, completion: @escaping @MainActor (Bool) -> Void) throws {
        bytes.append(data)
        self.completion = completion
    }
    func finishPending(_ success: Bool) {
        let pending = completion
        completion = nil
        pending?(success)
    }
}

@MainActor
final class ThemeStoreTests: XCTestCase {
    func testDisablingSoundsDuringPendingPlaybackPreservesBusinessAndConsumesMutedEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IncomeClock-SoundPending-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let events = ["clockInSuccess", "autoStop", "settlementComplete"]
        for event in events { try Data(event.utf8).write(to: root.appendingPathComponent(event + ".wav")) }
        let theme = ValidatedTheme(manifest: ValidatedTheme.warmIslandFallback.manifest,
            source: .installed(root: root), sounds: Dictionary(uniqueKeysWithValues: events.map { ($0, $0 + ".wav") }))
        let preferences = EphemeralThemePreferencesRepository()
        let themes = ThemeStore(repository: preferences, catalog: PendingSoundCatalog(theme: theme))
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 9))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current))
        let business = try BusinessStore(repository: repository, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let player = PendingSoundPlayer()
        let environment = AppEnvironment(businessStore: business, panelController: PanelControllerSpy(),
            themeStore: themes, themeSoundPlayer: player)
        await environment.start()
        await themes.setSoundsEnabled(true)
        let outcome = await business.send(.clockIn, source: .panel)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(player.bytes, [Data("clockInSuccess".utf8)])
        let before = business.viewState
        let today = business.todayRecordForValidation
        await themes.setSoundsEnabled(false)
        XCTAssertFalse(themes.soundsEnabled)
        XCTAssertEqual(business.viewState, before)
        XCTAssertEqual(business.todayRecordForValidation, today)
        player.finishPending(false)
        XCTAssertEqual(environment.themeSoundCoordinator.diagnostics.map(\.failure), [.playbackFailed])
        XCTAssertEqual(business.viewState, before)
        XCTAssertEqual(business.todayRecordForValidation, today)
        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        await business.refresh()
        XCTAssertEqual(business.viewState?.state, .awaitingClockOut)
        XCTAssertEqual(player.bytes.count, 1, "A new event while muted must not start playback")
        await themes.setSoundsEnabled(true)
        await business.refresh()
        XCTAssertEqual(player.bytes.count, 1, "Re-enabling must not replay the consumed auto-stop")
        let settlement = await business.send(.requestClockOut, source: .menuBar)
        XCTAssertEqual(settlement, .committed)
        XCTAssertEqual(player.bytes, [Data("clockInSuccess".utf8), Data("settlementComplete".utf8)])
        player.finishPending(true)
        await business.refresh()
        XCTAssertEqual(player.bytes.count, 2)
        // The pending player controls completion, not the coordinator or business
        // implementation. This does not claim immediate physical audio cancellation.
    }

    func testUnsupportedAppearanceResolvesEntireDefaultGroupForExplicitAndSystemModes() async throws {
        let catalog = await BundledThemeCatalog().loadBuiltInThemes()
        let themeB = try XCTUnwrap(catalog.themes.first { $0.id == BuiltinThemeID.windowCompanion })
        for supported in [PreferredThemeAppearance.light, .dark] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(themeB.manifest)) as? [String: Any])
            object["supportedAppearances"] = [supported.rawValue]
            let manifest = try JSONDecoder().decode(ThemeManifest.self,
                from: JSONSerialization.data(withJSONObject: object))
            let theme = ValidatedTheme(manifest: manifest)
            let unsupported: PreferredThemeAppearance = supported == .light ? .dark : .light
            for preference in [unsupported, .system] {
                let result = ThemeAppearanceResolver.resolve(theme: theme, preferred: preference,
                    systemIsDark: unsupported == .dark)
                XCTAssertEqual(result.themeID, BuiltinThemeID.warmIsland)
                XCTAssertEqual(result.colors, ValidatedTheme.warmIslandFallback.colors(dark: unsupported == .dark))
                XCTAssertEqual(result.appearance, unsupported == .dark ? .dark : .light)
            }
            let available = ThemeAppearanceResolver.resolve(theme: theme, preferred: supported,
                systemIsDark: unsupported == .dark)
            XCTAssertEqual(available.themeID, theme.id)
            XCTAssertEqual(available.colors, theme.colors(dark: supported == .dark))
            let preferences = EphemeralThemePreferencesRepository()
            let store = ThemeStore(repository: preferences,
                catalog: PendingSoundCatalog(theme: theme))
            await store.restore()
            await store.setAppearance(supported)
            await store.selectTheme(id: theme.id)
            XCTAssertEqual(store.selectedTheme.id, theme.id)
            await store.setAppearance(unsupported)
            XCTAssertEqual(store.effectiveTheme(systemIsDark: unsupported == .dark), .warmIslandFallback)
            XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
            XCTAssertNotNil(store.viewState.fallbackNotice)
            guard case let .loaded(saved, _) = await preferences.loadThemePreferences() else {
                return XCTFail("Expected persisted fallback")
            }
            XCTAssertEqual(saved.selectedThemeId, BuiltinThemeID.warmIsland)
            await store.setAppearance(supported)
            XCTAssertEqual(store.effectiveTheme(systemIsDark: unsupported == .dark), .warmIslandFallback)
            XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland, "Mode changes cannot reselect the former theme")
            XCTAssertNil(store.appearanceFallbackNotice(systemIsDark: unsupported == .dark))
        }
    }

    func testSystemAppearanceFallbackPersistsAOrReportsFailedSaveWithoutChangingBusiness() async throws {
        let catalog = await BundledThemeCatalog().loadBuiltInThemes()
        let original = try XCTUnwrap(catalog.themes.first { $0.id == BuiltinThemeID.windowCompanion })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original.manifest)) as? [String: Any])
        object["supportedAppearances"] = ["light"]
        let theme = ValidatedTheme(manifest: try JSONDecoder().decode(ThemeManifest.self,
            from: JSONSerialization.data(withJSONObject: object)))
        for fails in [false, true] {
            let record = themePreferences(revision: 7, themeID: theme.id, appearance: .system, sounds: true)
            let preferences = ThemePreferencesRepositorySpy(loadResult: .loaded(record, migration: .current), failSaves: fails)
            let themes = ThemeStore(repository: preferences, catalog: PendingSoundCatalog(theme: theme))
            let business = try BusinessStore(repository: BusinessRecordRepositorySpy(
                settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)),
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await business.restore()
            let before = business.viewState
            let settings = business.settingsRecordForValidation
            let today = business.todayRecordForValidation
            await themes.restore()
            XCTAssertEqual(themes.selectedTheme.id, theme.id)
            await themes.reconcileAppearance(systemIsDark: true)
            XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
            XCTAssertEqual(themes.effectiveTheme(systemIsDark: true), .warmIslandFallback)
            XCTAssertFalse(themes.viewState.isProcessing)
            XCTAssertNotNil(themes.viewState.fallbackNotice)
            let stored = await preferences.currentRecord()
            XCTAssertEqual(stored?.selectedThemeId, fails ? theme.id : BuiltinThemeID.warmIsland)
            XCTAssertEqual(themes.viewState.error, fails ? .persistenceFailed : nil)
            if fails { XCTAssertTrue(themes.viewState.fallbackNotice?.contains("未能保存") == true) }
            await themes.reconcileAppearance(systemIsDark: false)
            XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
            XCTAssertEqual(business.viewState, before)
            XCTAssertEqual(business.settingsRecordForValidation, settings)
            XCTAssertEqual(business.todayRecordForValidation, today)
        }
    }

    func testSystemAppearanceChangeDuringSuccessfulOrFailedCommitReconcilesFinalMode() async throws {
        let catalog = await BundledThemeCatalog().loadBuiltInThemes()
        let original = try XCTUnwrap(catalog.themes.first { $0.id == BuiltinThemeID.windowCompanion })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original.manifest)) as? [String: Any])
        object["supportedAppearances"] = ["light"]
        let theme = ValidatedTheme(manifest: try JSONDecoder().decode(ThemeManifest.self,
            from: JSONSerialization.data(withJSONObject: object)))
        for failFirst in [false, true] {
            let preferences = AppearanceCommitGate(record: themePreferences(revision: 1, themeID: theme.id), failFirst: failFirst)
            let themes = ThemeStore(repository: preferences, catalog: PendingSoundCatalog(theme: theme))
            await themes.restore()
            let save = Task { await themes.setSoundsEnabled(true) }
            await preferences.waitUntilSaving()
            XCTAssertTrue(themes.viewState.isProcessing)
            await themes.reconcileAppearance(systemIsDark: true)
            await preferences.release()
            await save.value
            XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
            XCTAssertEqual(themes.soundsEnabled, !failFirst)
            XCTAssertFalse(themes.viewState.isProcessing)
            guard case let .loaded(record, _) = await preferences.loadThemePreferences() else {
                return XCTFail("Expected final persisted preference")
            }
            XCTAssertEqual(record.selectedThemeId, BuiltinThemeID.warmIsland)
            let count = await preferences.saveCount
            XCTAssertEqual(count, 2)
        }
    }

    func testBundledCatalogValidatesAAndBWithStableReservedIDs() async throws {
        let snapshot = await BundledThemeCatalog().loadBuiltInThemes()

        XCTAssertEqual(snapshot.diagnostics, [])
        XCTAssertEqual(Set(snapshot.themes.map(\.id)), Set([
            BuiltinThemeID.warmIsland,
            BuiltinThemeID.windowCompanion
        ]))
        let themeA = try XCTUnwrap(snapshot.themes.first { $0.id == BuiltinThemeID.warmIsland })
        let themeB = try XCTUnwrap(snapshot.themes.first { $0.id == BuiltinThemeID.windowCompanion })
        XCTAssertTrue(themeA.isDefault)
        XCTAssertFalse(themeB.isDefault)
        XCTAssertEqual(themeB.manifest.metrics.panelCornerRadius, 18)
        for state in [WorkdayState.ready, .clockedInWaiting, .earning, .awaitingClockOut, .completed] {
            XCTAssertNotNil(themeB.decorationResource(for: state))
        }
        XCTAssertNil(themeB.decorationResource(for: .unconfigured))
        XCTAssertNil(themeB.decorationResource(for: .recoveryRequired))
    }

    func testBundledThemesMatchApprovedNamesMetricsAndLightDarkTokenGroups() async throws {
        let snapshot = await BundledThemeCatalog().loadBuiltInThemes()
        let themeA = try XCTUnwrap(snapshot.themes.first { $0.id == BuiltinThemeID.warmIsland })
        let themeB = try XCTUnwrap(snapshot.themes.first { $0.id == BuiltinThemeID.windowCompanion })

        XCTAssertEqual(themeA.name, "暖屿")
        XCTAssertEqual(themeA.manifest.light, ValidatedTheme.warmIslandFallback.manifest.light)
        XCTAssertEqual(themeA.manifest.dark, ValidatedTheme.warmIslandFallback.manifest.dark)
        XCTAssertEqual(themeB.name, "窗边搭子")
        XCTAssertEqual(themeB.manifest.amountFontDesign, .rounded)
        XCTAssertEqual(themeB.manifest.amountFontWeight, "semibold")
        XCTAssertEqual(themeB.manifest.metrics, ThemeMetricTokens(
            panelCornerRadius: 18,
            buttonCornerRadius: 10,
            progressHeight: 5,
            borderWidth: 1,
            decorationOpacity: 0.72
        ))
        XCTAssertEqual(themeB.manifest.light, BuiltinThemeValidator.approvedWindowCompanionLight)
        XCTAssertEqual(themeB.manifest.dark, BuiltinThemeValidator.approvedWindowCompanionDark)
    }

    func testThemeBPublicIdentityAndLicenseUseApprovedName() async throws {
        let snapshot = await BundledThemeCatalog().loadBuiltInThemes()
        let themeB = try XCTUnwrap(snapshot.themes.first { $0.id == BuiltinThemeID.windowCompanion })
        XCTAssertEqual(themeB.name, "窗边搭子")
        XCTAssertFalse(themeB.manifest.licenseOrSource.contains("窗边小伙伴"))

        let licenseURL = try XCTUnwrap(ThemeResourceBundle.bundle.url(
            forResource: "LICENSE",
            withExtension: "txt",
            subdirectory: "BuiltinThemes/\(BuiltinThemeID.windowCompanion)"
        ))
        let license = try String(contentsOf: licenseURL, encoding: .utf8)
        XCTAssertTrue(license.contains("窗边搭子（B）"))
        XCTAssertFalse(license.contains("窗边小伙伴"))
    }

    func testSettingsPreviewResolverUsesOneCompleteResolvedAppearanceGroup() async throws {
        let snapshot = await BundledThemeCatalog().loadBuiltInThemes()
        for theme in snapshot.themes {
            let systemLight = ThemeAppearanceResolver.resolve(
                theme: theme,
                preferred: .system,
                systemIsDark: false
            )
            let systemDark = ThemeAppearanceResolver.resolve(
                theme: theme,
                preferred: .system,
                systemIsDark: true
            )
            let forcedLight = ThemeAppearanceResolver.resolve(
                theme: theme,
                preferred: .light,
                systemIsDark: true
            )
            let forcedDark = ThemeAppearanceResolver.resolve(
                theme: theme,
                preferred: .dark,
                systemIsDark: false
            )

            XCTAssertEqual(systemLight.appearance, .light)
            XCTAssertEqual(systemLight.colors, theme.manifest.light)
            XCTAssertEqual(systemDark.appearance, .dark)
            XCTAssertEqual(systemDark.colors, theme.manifest.dark)
            XCTAssertEqual(forcedLight.colors, theme.manifest.light)
            XCTAssertEqual(forcedDark.colors, theme.manifest.dark)
            XCTAssertNotEqual(systemLight.colors, systemDark.colors)
        }
    }

    func testPrimaryActionStatesMeetContrastForAAndBInLightAndDark() async throws {
        let snapshot = await BundledThemeCatalog().loadBuiltInThemes()
        XCTAssertEqual(snapshot.themes.count, 2)

        for theme in snapshot.themes {
            for (appearance, tokens) in [("light", theme.manifest.light), ("dark", theme.manifest.dark)] {
                for role in ThemePrimaryActionRole.allCases {
                    for state in ThemeControlState.allCases {
                        let visual = try XCTUnwrap(ThemeButtonStyleResolver.resolve(
                            role: role,
                            state: state,
                            tokens: tokens
                        ), "\(theme.id).\(appearance).\(role).\(state)")
                        XCTAssertGreaterThanOrEqual(
                            ThemeContrast.ratio(
                                foreground: visual.foreground,
                                background: visual.background
                            ),
                            4.5,
                            "\(theme.id).\(appearance).\(role).\(state)"
                        )
                        XCTAssertGreaterThanOrEqual(visual.opacity, 0.45)
                        XCTAssertEqual(visual.showsFocusRing, state == .focused)
                        if state == .focused {
                            XCTAssertGreaterThanOrEqual(
                                ThemeContrast.ratio(
                                    foreground: visual.focusRing,
                                    background: tokens.background
                                ),
                                3,
                                "\(theme.id).\(appearance).focusRing"
                            )
                        }
                    }
                    let hover = try XCTUnwrap(ThemeButtonStyleResolver.resolve(
                        role: role,
                        state: .hover,
                        tokens: tokens
                    ))
                    let pressed = try XCTUnwrap(ThemeButtonStyleResolver.resolve(
                        role: role,
                        state: .pressed,
                        tokens: tokens
                    ))
                    if role == .destructive {
                        XCTAssertEqual(hover.background, tokens.statusError)
                        XCTAssertEqual(pressed.background, tokens.statusError)
                    } else {
                        XCTAssertEqual(hover.background, tokens.accentHover)
                        XCTAssertEqual(pressed.background, tokens.accentPressed)
                    }
                }
            }
        }
    }

    func testLowContrastThemeIsRejectedAndUnsafeActionTextFallsBackSafely() async throws {
        let snapshot = await BundledThemeCatalog().loadBuiltInThemes()
        let themeB = try XCTUnwrap(snapshot.themes.first { $0.id == BuiltinThemeID.windowCompanion })

        let badPrimary = try replacingColor(
            in: themeB.manifest,
            appearance: "light",
            token: "primaryText",
            with: themeB.manifest.light.background
        )
        XCTAssertThrowsError(try BuiltinThemeValidator.validate(badPrimary)) { error in
            XCTAssertEqual(error as? ThemeValidationIssue, .insufficientContrast("light.primaryText"))
        }

        let badFocus = try replacingColor(
            in: themeB.manifest,
            appearance: "dark",
            token: "focusRing",
            with: themeB.manifest.dark.background
        )
        XCTAssertThrowsError(try BuiltinThemeValidator.validate(badFocus)) { error in
            XCTAssertEqual(error as? ThemeValidationIssue, .insufficientContrast("dark.focusRing"))
        }

        let unsafeAction = try replacingColor(
            in: themeB.manifest,
            appearance: "light",
            token: "actionText",
            with: themeB.manifest.light.start
        )
        let visual = try XCTUnwrap(ThemeButtonStyleResolver.resolve(
            role: .start,
            state: .normal,
            tokens: unsafeAction.light
        ))
        XCTAssertNotEqual(visual.foreground, unsafeAction.light.actionText)
        XCTAssertTrue(["#000000", "#FFFFFF"].contains(visual.foreground))
        XCTAssertGreaterThanOrEqual(
            ThemeContrast.ratio(foreground: visual.foreground, background: visual.background),
            4.5
        )
        XCTAssertThrowsError(try BuiltinThemeValidator.validate(unsafeAction)) { error in
            XCTAssertEqual(error as? ThemeValidationIssue, .contractMismatch("light"))
        }
    }

    func testAllStatusVisualAndTextTokensMeetContrastWithDeterministicFallback() async throws {
        let snapshot = await BundledThemeCatalog().loadBuiltInThemes()
        for theme in snapshot.themes {
            for (appearance, tokens, fallback) in [
                ("light", theme.manifest.light, ValidatedTheme.warmIslandFallback.manifest.light),
                ("dark", theme.manifest.dark, ValidatedTheme.warmIslandFallback.manifest.dark)
            ] {
                for role in ThemeStatusRole.allCases {
                    let resolved = try XCTUnwrap(ThemeStatusStyleResolver.resolve(
                        role: role,
                        tokens: tokens,
                        safeFallback: fallback
                    ))
                    XCTAssertGreaterThanOrEqual(
                        ThemeContrast.ratio(foreground: resolved.emphasis, background: tokens.background),
                        3,
                        "\(theme.id).\(appearance).status.\(role.rawValue).emphasis"
                    )
                    XCTAssertGreaterThanOrEqual(
                        ThemeContrast.ratio(foreground: resolved.text, background: tokens.background),
                        4.5,
                        "\(theme.id).\(appearance).status.\(role.rawValue).text"
                    )
                    XCTAssertEqual(resolved.text, tokens.primaryText.uppercased())
                }
            }
        }

        let themeB = try XCTUnwrap(snapshot.themes.first { $0.id == BuiltinThemeID.windowCompanion })
        XCTAssertEqual(
            ThemeContrast.ratio(
                foreground: themeB.manifest.light.statusWaiting,
                background: themeB.manifest.light.background
            ),
            2.803092,
            accuracy: 0.000001
        )
        let waiting = try XCTUnwrap(ThemeStatusStyleResolver.resolve(
            role: .waiting,
            tokens: themeB.manifest.light,
            safeFallback: ValidatedTheme.warmIslandFallback.manifest.light
        ))
        XCTAssertTrue(waiting.usedSafetyFallback)
        XCTAssertEqual(
            waiting.emphasis,
            ValidatedTheme.warmIslandFallback.manifest.light.primaryText
        )
    }

    func testUnrecoverableLowContrastStatusIsRejectedByValidatorBoundary() throws {
        let unsafe = try replacingColors(
            in: ValidatedTheme.warmIslandFallback.manifest.light,
            with: [
                "background": "#777777",
                "primaryText": "#777777",
                "statusReady": "#777777",
                "statusWaiting": "#777777",
                "statusEarning": "#777777",
                "statusAwaiting": "#777777",
                "statusCompleted": "#777777",
                "statusError": "#777777"
            ]
        )
        XCTAssertNil(ThemeStatusStyleResolver.resolve(
            role: .waiting,
            tokens: unsafe,
            safeFallback: unsafe
        ))
        XCTAssertThrowsError(try BuiltinThemeValidator.validateStatusContrast(
            unsafe,
            name: "probe",
            safeFallback: unsafe
        )) { error in
            XCTAssertEqual(
                error as? ThemeValidationIssue,
                .insufficientContrast("probe.status.ready")
            )
        }
    }

    func testAppearanceTransactionPolicyIsAtomicAndHonorsAccessibilityOverrides() async throws {
        let catalog = await BundledThemeCatalog().loadBuiltInThemes()
        let themeB = try XCTUnwrap(catalog.themes.first {
            $0.id == BuiltinThemeID.windowCompanion
        })
        let normal = ThemeAppearanceTransitionPolicy.resolve(
            reduceMotion: false,
            reduceTransparency: false
        )
        XCTAssertEqual(normal.durationMilliseconds, 120)
        XCTAssertTrue(normal.usesCrossfade)
        XCTAssertFalse(normal.usesOpaqueSurfaces)

        let reducedMotion = ThemeAppearanceTransitionPolicy.resolve(
            reduceMotion: true,
            reduceTransparency: false
        )
        XCTAssertEqual(reducedMotion.durationMilliseconds, 0)
        XCTAssertFalse(reducedMotion.usesCrossfade)

        let reducedTransparency = ThemeAppearanceTransitionPolicy.resolve(
            reduceMotion: false,
            reduceTransparency: true
        )
        XCTAssertEqual(reducedTransparency.durationMilliseconds, 0)
        XCTAssertFalse(reducedTransparency.usesCrossfade)
        XCTAssertTrue(reducedTransparency.usesOpaqueSurfaces)

        let light = ThemeAppearanceResolver.resolve(
            theme: themeB,
            preferred: .light,
            systemIsDark: true
        )
        let dark = ThemeAppearanceResolver.resolve(
            theme: themeB,
            preferred: .dark,
            systemIsDark: false
        )
        XCTAssertEqual(light.colors, themeB.manifest.light)
        XCTAssertEqual(dark.colors, themeB.manifest.dark)
        XCTAssertNotEqual(light.colors.background, dark.colors.background)
    }

    func testMissingPreferencesRestoreSafeAWithSystemAppearanceAndSoundsOff() async {
        let repository = ThemePreferencesRepositorySpy(loadResult: .missing)
        let store = ThemeStore(repository: repository, catalog: await fixedCatalog())

        await store.restore()

        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertEqual(store.preferredAppearance, .system)
        XCTAssertFalse(store.soundsEnabled)
        XCTAssertNil(store.viewState.error)
        let saveCount = await repository.saveCount()
        XCTAssertEqual(saveCount, 0)
    }

    func testStoredBAndDarkAppearanceRestoreWithoutChangingValues() async {
        let record = themePreferences(
            revision: 7,
            themeID: BuiltinThemeID.windowCompanion,
            appearance: .dark,
            sounds: true
        )
        let repository = ThemePreferencesRepositorySpy(loadResult: .loaded(record, migration: .current))
        let store = ThemeStore(repository: repository, catalog: await fixedCatalog())

        await store.restore()

        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.windowCompanion)
        XCTAssertEqual(store.preferredAppearance, .dark)
        XCTAssertTrue(store.soundsEnabled)
        let saveCount = await repository.saveCount()
        XCTAssertEqual(saveCount, 0)
    }

    func testDamagedPreferencesRemainPreservedUntilExplicitSelectionRecoversThem() async {
        let damage = DamagedRecordResult(
            kind: .themePreferences,
            issue: .decodingFailed,
            disposition: .useDefaultThemePreferences
        )
        let repository = ThemePreferencesRepositorySpy(loadResult: .damaged(damage))
        let store = ThemeStore(repository: repository, catalog: await fixedCatalog())

        await store.restore()
        XCTAssertEqual(store.viewState.error, .preferencesDamaged)
        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        let initialRecoveryCount = await repository.recoveryCount()
        XCTAssertEqual(initialRecoveryCount, 0)

        await store.selectTheme(id: BuiltinThemeID.windowCompanion)

        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.windowCompanion)
        let recoveryCount = await repository.recoveryCount()
        let saveCount = await repository.saveCount()
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(saveCount, 0)
        XCTAssertNil(store.viewState.error)
    }

    func testUnavailableStoredThemeFallsBackToAAndPersistsSafePreference() async {
        let record = themePreferences(revision: 2, themeID: "app.incomeclock.removed")
        let repository = ThemePreferencesRepositorySpy(loadResult: .loaded(record, migration: .current))
        let store = ThemeStore(repository: repository, catalog: await fixedCatalog())

        await store.restore()

        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertEqual(store.preferredAppearance, .system)
        XCTAssertFalse(store.soundsEnabled)
        let saveCount = await repository.saveCount()
        let lastSavedThemeID = await repository.lastSavedThemeID()
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(lastSavedThemeID, BuiltinThemeID.warmIsland)
        XCTAssertTrue(store.viewState.fallbackNotice?.contains("已回退") == true)
    }

    func testPersistenceFailureKeepsOriginalThemeAppearanceAndSoundState() async {
        let record = themePreferences(revision: 3, themeID: BuiltinThemeID.warmIsland)
        let repository = ThemePreferencesRepositorySpy(
            loadResult: .loaded(record, migration: .current),
            failSaves: true
        )
        let store = ThemeStore(repository: repository, catalog: await fixedCatalog())
        await store.restore()

        await store.selectTheme(id: BuiltinThemeID.windowCompanion)
        await store.setAppearance(.dark)
        await store.setSoundsEnabled(true)

        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertEqual(store.preferredAppearance, .system)
        XCTAssertFalse(store.soundsEnabled)
        XCTAssertEqual(store.viewState.error, .persistenceFailed)
    }

    func testThemeAppearanceAndSoundChangesCommitOnePreferenceRecordAtATime() async {
        let repository = ThemePreferencesRepositorySpy(loadResult: .missing)
        let store = ThemeStore(repository: repository, catalog: await fixedCatalog())
        await store.restore()

        await store.selectTheme(id: BuiltinThemeID.windowCompanion)
        await store.setAppearance(.light)
        await store.setSoundsEnabled(true)

        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.windowCompanion)
        XCTAssertEqual(store.preferredAppearance, .light)
        XCTAssertTrue(store.soundsEnabled)
        let saveCount = await repository.saveCount()
        let currentRevision = await repository.currentRecord()?.revision.rawValue
        XCTAssertEqual(saveCount, 3)
        XCTAssertEqual(currentRevision, 3)
    }

    func testAccessibilityPolicyHonorsReduceMotionAndReduceTransparency() async throws {
        let catalog = await fixedCatalog()
        let themeB = try XCTUnwrap(catalog.snapshot.themes.first {
            $0.id == BuiltinThemeID.windowCompanion
        })
        let normal = ThemeAccessibilityPolicy.resolve(
            metrics: themeB.manifest.metrics,
            reduceMotion: false,
            reduceTransparency: false
        )
        let reduced = ThemeAccessibilityPolicy.resolve(
            metrics: themeB.manifest.metrics,
            reduceMotion: true,
            reduceTransparency: true
        )

        XCTAssertTrue(normal.allowsDecorationMotion)
        XCTAssertFalse(normal.usesOpaqueBackground)
        XCTAssertEqual(normal.decorationOpacity, 0.72)
        XCTAssertFalse(reduced.allowsDecorationMotion)
        XCTAssertTrue(reduced.usesOpaqueBackground)
        XCTAssertGreaterThan(reduced.decorationOpacity, normal.decorationOpacity)
        XCTAssertEqual(ThemePanelLayout.primaryActionWidth, 296)
        XCTAssertEqual(ThemePanelLayout.primaryActionHeight, 32)
        XCTAssertEqual(ThemePanelLayout.decorationWidth, 60)
        XCTAssertEqual(ThemePanelLayout.decorationHeight, 50)
        XCTAssertEqual(ThemePanelLayout.decorationContentInset, 3)
        XCTAssertFalse(ThemePanelLayout.decorationAllowsHitTesting)
    }

    func testThemeChangesDoNotModifySettingsOrTodayBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClock-Stage7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)
        _ = try await repository.saveSettings(ApplicationTestSupport.proposedSettings(), expectedRevision: nil)
        let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let today = try calendar.proposedToday(
            from: ApplicationTestSupport.committedSettings(),
            at: ApplicationTestSupport.timestamp(hour: 10)
        )
        _ = try await repository.saveToday(today, expectedRevision: nil)
        let settingsBefore = try Data(contentsOf: paths.settings)
        let todayBefore = try Data(contentsOf: paths.today)
        let store = ThemeStore(repository: repository, catalog: await fixedCatalog())
        await store.restore()

        await store.selectTheme(id: BuiltinThemeID.windowCompanion)
        await store.setAppearance(.dark)

        XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBefore)
        XCTAssertEqual(try Data(contentsOf: paths.today), todayBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.themePreferences.path))
    }

    func testBStateAssetsCompileAndPanelRendersAAndBInLightAndDark() async throws {
        for name in ["ThemeBReady", "ThemeBWaiting", "ThemeBEarning", "ThemeBAwaitingClockOut", "ThemeBCompleted"] {
            XCTAssertNotNil(ThemeResourceBundle.bundle.image(forResource: name), "Missing compiled asset \(name)")
        }

        let businessRepository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current),
            today: .missing
        )
        let businessStore = try BusinessStore(
            repository: businessRepository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        await businessStore.restore()
        let themeRepository = ThemePreferencesRepositorySpy(loadResult: .missing)
        let themeStore = ThemeStore(repository: themeRepository, catalog: await fixedCatalog())
        await themeStore.restore()
        let profile = PanelPresentationProfileRegistry().standard

        for themeID in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
            await themeStore.selectTheme(id: themeID)
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: IncomePanelView(
                    businessStore: businessStore,
                    themeStore: themeStore,
                    profile: profile,
                    onOpenSettings: {},
                    onHide: {}
                ).environment(\.colorScheme, scheme))
                host.frame = CGRect(origin: .zero, size: profile.contentSize)
                host.layoutSubtreeIfNeeded()
                let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: representation)
                XCTAssertEqual(host.bounds.size, profile.contentSize)
                XCTAssertEqual(representation.pixelsHigh * 32, representation.pixelsWide * 19)
                addAttachment(
                    representation,
                    size: profile.contentSize,
                    name: "Stage7-\(themeID)-\(scheme == .light ? "Light" : "Dark")"
                )
                try writeRenderIfRequested(
                    representation,
                    filename: "\(themeID)-\(scheme == .light ? "light" : "dark").png"
                )
            }
        }
    }

    func testRepairEvidenceRendersInteractionAccessibilityAndAppearanceFrames() async throws {
        let businessRepository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current),
            today: .missing
        )
        let businessStore = try BusinessStore(
            repository: businessRepository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        await businessStore.restore()
        let businessStateBefore = businessStore.viewState
        let themeStore = ThemeStore(
            repository: ThemePreferencesRepositorySpy(loadResult: .missing),
            catalog: await fixedCatalog()
        )
        await themeStore.restore()
        let profile = PanelPresentationProfileRegistry().standard
        var evidenceRows = [
            "theme\tappearance\tvariant\twidth\theight\tproductView\twindow\teventSequence" +
            "\teventTarget\tsemanticFocus\thitRect\tresolvedBackground\trenderedBackground" +
            "\tresolvedTextContrast\trasterObservedContrast\trawResult"
        ]

        for themeID in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
            await themeStore.selectTheme(id: themeID)
            let theme = themeStore.selectedTheme
            for scheme in [ColorScheme.light, .dark] {
                let appearance = scheme == .light ? "light" : "dark"
                await themeStore.setAppearance(scheme == .light ? .light : .dark)
                let group = ThemeAppearanceResolver.resolve(
                    theme: theme,
                    preferred: scheme == .light ? .light : .dark,
                    systemIsDark: scheme == .dark
                )
                var interactionPNGs: [ThemeControlState: Data] = [:]
                for state in [ThemeControlState.normal, .hover, .pressed, .focused] {
                    let name = "\(themeID)-\(appearance)-\(state.rawValue)"
                    let harness = try ProductPanelInteractionHarness(
                        businessStore: businessStore,
                        themeStore: themeStore,
                        profile: profile
                    )
                    let observation = try await harness.transition(to: state)
                    let representation = try harness.snapshot()
                    harness.finishInteraction(state)
                    harness.close()
                    let png = try XCTUnwrap(
                        representation.representation(using: .png, properties: [:])
                    )
                    interactionPNGs[state] = png
                    XCTAssertEqual(representation.pixelsWide, 640)
                    XCTAssertEqual(representation.pixelsHigh, 380)
                    XCTAssertEqual(observation.productView, "IncomePanelView")
                    XCTAssertEqual(observation.window, "IncomePanel")
                    XCTAssertGreaterThanOrEqual(observation.hitRect.width, 294)
                    XCTAssertLessThanOrEqual(observation.hitRect.width, 298)
                    XCTAssertGreaterThanOrEqual(observation.hitRect.height, 30)
                    XCTAssertLessThanOrEqual(observation.hitRect.height, 34)
                    if state == .focused {
                        XCTAssertEqual(observation.semanticFocus, "primary")
                    } else {
                        XCTAssertEqual(observation.semanticFocus, "none")
                    }
                    let visual = try XCTUnwrap(ThemeButtonStyleResolver.resolve(
                        role: .start,
                        state: state,
                        tokens: group.colors
                    ))
                    XCTAssertTrue(observation.hostIsFlipped, name)
                    let renderedMetrics = renderedButtonMetrics(
                        representation,
                        hitRect: observation.hitRect,
                        coordinateSpaceIsFlipped: observation.hostIsFlipped,
                        context: name
                    )
                    let resolvedContrast = ThemeContrast.ratio(
                        foreground: visual.foreground,
                        background: visual.background
                    )
                    XCTAssertGreaterThanOrEqual(resolvedContrast, 4.5, name)
                    XCTAssertGreaterThan(renderedMetrics.distinctTextPixels, 0, name)
                    try recordEvidence(representation, name: name)
                    evidenceRows.append([
                        themeID,
                        appearance,
                        state.rawValue,
                        "320",
                        "190",
                        observation.productView,
                        observation.window,
                        observation.eventSequence,
                        observation.eventTarget,
                        observation.semanticFocus,
                        observation.hitRect.tsvValue,
                        visual.background,
                        renderedMetrics.backgroundHex,
                        String(format: "%.6f", resolvedContrast),
                        String(format: "%.6f", renderedMetrics.textContrast),
                        "S7R003FreshRenderFinal.xcresult#testRepairEvidenceRendersInteractionAccessibilityAndAppearanceFrames"
                    ].joined(separator: "\t"))
                }
                XCTAssertEqual(interactionPNGs.count, 4)
                XCTAssertNotEqual(interactionPNGs[.normal], interactionPNGs[.hover])
                XCTAssertNotEqual(interactionPNGs[.hover], interactionPNGs[.pressed])
                XCTAssertNotEqual(interactionPNGs[.normal], interactionPNGs[.focused])

                for variant in ["reduce-motion", "reduce-transparency"] {
                    let view = IncomePanelView(
                        businessStore: businessStore,
                        themeStore: themeStore,
                        profile: profile,
                        onOpenSettings: {},
                        onHide: {},
                        accessibilityInputs: .init(
                            reduceMotion: variant == "reduce-motion",
                            reduceTransparency: variant == "reduce-transparency"
                        )
                    )
                    .environment(\.colorScheme, scheme)
                    let representation = try render(view, size: profile.contentSize)
                    try recordEvidence(
                        representation,
                        name: "\(themeID)-\(appearance)-\(variant)"
                    )
                    evidenceRows.append([
                        themeID, appearance, variant, "320", "190", "IncomePanelView", "NSHostingView",
                        "accessibilityInputs:\(variant)", "IncomePanelView", "none", "12,10,296,32",
                        "n/a", "n/a", "n/a", "n/a",
                        "S7R003FreshRenderFinal.xcresult#testRepairEvidenceRendersInteractionAccessibilityAndAppearanceFrames"
                    ].joined(separator: "\t"))
                }
            }

            await themeStore.setAppearance(.system)
            let probe = ThemeAppearanceProbe()
            let probeView = ThemeAppearanceProbeView(
                probe: probe,
                businessStore: businessStore,
                themeStore: themeStore,
                profile: profile
            )
            let host = NSHostingView(rootView: probeView)
            host.frame = CGRect(origin: .zero, size: profile.contentSize)
            let window = NSWindow(
                contentRect: CGRect(
                    origin: CGPoint(x: -10_000, y: -10_000),
                    size: profile.contentSize
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.hasShadow = false
            window.isOpaque = false
            window.contentView = host
            window.orderBack(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let frame000 = try bitmap(from: host)
            try recordEvidence(
                frame000,
                name: "\(themeID)-appearance-frame-000ms"
            )
            probe.isDark = true
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 60_000_000)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let frame060 = try bitmap(from: host)
            try recordEvidence(
                frame060,
                name: "\(themeID)-appearance-frame-060ms"
            )
            try await Task.sleep(nanoseconds: 80_000_000)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let frame140 = try bitmap(from: host)
            try recordEvidence(
                frame140,
                name: "\(themeID)-appearance-frame-140ms"
            )
            let png000 = try XCTUnwrap(frame000.representation(using: .png, properties: [:]))
            let png060 = try XCTUnwrap(frame060.representation(using: .png, properties: [:]))
            let png140 = try XCTUnwrap(frame140.representation(using: .png, properties: [:]))
            XCTAssertNotEqual(png000, png060, "60 ms must be a distinct crossfade frame")
            XCTAssertNotEqual(png060, png140, "140 ms must reach a distinct final frame")
            XCTAssertNotEqual(png000, png140, "appearance transaction must reach dark")
            for frame in ["frame-000ms", "frame-060ms", "frame-140ms"] {
                evidenceRows.append([
                    themeID, "light-to-dark", frame, "320", "190", "IncomePanelView", "NSWindow",
                    "ThemeAppearanceProbe.isDark:false-to-true", "IncomePanelView", "none",
                    "12,10,296,32", "n/a", "n/a", "n/a", "n/a",
                    "S7R003FreshRenderFinal.xcresult#testRepairEvidenceRendersInteractionAccessibilityAndAppearanceFrames"
                ].joined(separator: "\t"))
            }
        }

        XCTAssertEqual(profile.contentSize, CGSize(width: 320, height: 190))
        XCTAssertEqual(ThemePanelLayout.primaryActionWidth, 296)
        XCTAssertEqual(ThemePanelLayout.primaryActionHeight, 32)
        XCTAssertFalse(ThemePanelLayout.decorationAllowsHitTesting)
        XCTAssertEqual(businessStore.viewState, businessStateBefore)
        try writeEvidenceLogIfRequested(evidenceRows.joined(separator: "\n") + "\n")
    }

    private func fixedCatalog() async -> FixedThemeCatalog {
        FixedThemeCatalog(snapshot: await BundledThemeCatalog().loadBuiltInThemes())
    }

    private func replacingColor(
        in manifest: ThemeManifest,
        appearance: String,
        token: String,
        with value: String
    ) throws -> ThemeManifest {
        let encoded = try JSONEncoder().encode(manifest)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var colors = try XCTUnwrap(object[appearance] as? [String: Any])
        colors[token] = value
        object[appearance] = colors
        return try JSONDecoder().decode(
            ThemeManifest.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func replacingColors(
        in tokens: ThemeColorTokens,
        with replacements: [String: String]
    ) throws -> ThemeColorTokens {
        let encoded = try JSONEncoder().encode(tokens)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for (key, value) in replacements { object[key] = value }
        return try JSONDecoder().decode(
            ThemeColorTokens.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func themePreferences(
        revision: UInt64,
        themeID: String,
        appearance: PreferredThemeAppearance = .system,
        sounds: Bool = false
    ) -> ThemePreferencesRecord {
        ThemePreferencesRecord(
            schemaVersion: ThemePreferencesRecord.currentSchemaVersion,
            revision: .init(rawValue: revision),
            selectedThemeId: themeID,
            preferredThemeAppearance: appearance,
            themeSoundsEnabled: sounds,
            updatedAtMs: 1
        )
    }

    private func addAttachment(_ representation: NSBitmapImageRep, size: CGSize, name: String) {
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func writeRenderIfRequested(_ representation: NSBitmapImageRep, filename: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["INCOMECLOCK_STAGE7_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory, isDirectory: true),
            withIntermediateDirectories: true
        )
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename), options: .atomic)
    }

    private func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return try bitmap(from: host)
    }

    private func bitmap<V: View>(from host: NSHostingView<V>) throws -> NSBitmapImageRep {
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        XCTAssertEqual(representation.pixelsHigh * 32, representation.pixelsWide * 19)
        return representation
    }

    private func recordEvidence(_ representation: NSBitmapImageRep, name: String) throws {
        addAttachment(representation, size: CGSize(width: 320, height: 190), name: name)
        try writeRenderIfRequested(representation, filename: "\(name).png")
    }

    private func renderedButtonMetrics(
        _ representation: NSBitmapImageRep,
        hitRect: CGRect,
        coordinateSpaceIsFlipped: Bool,
        context: String
    ) -> RenderedButtonMetrics {
        let scaleX = CGFloat(representation.pixelsWide) / 320
        let scaleY = CGFloat(representation.pixelsHigh) / 190
        let minX = Int((hitRect.minX + 18) * scaleX)
        let maxX = Int((hitRect.maxX - 18) * scaleX)
        let minY = coordinateSpaceIsFlipped
            ? Int((hitRect.minY + 4) * scaleY)
            : representation.pixelsHigh - Int((hitRect.maxY - 4) * scaleY)
        let maxY = coordinateSpaceIsFlipped
            ? Int((hitRect.maxY - 4) * scaleY)
            : representation.pixelsHigh - Int((hitRect.minY + 4) * scaleY)
        var histogram: [UInt32: Int] = [:]
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                histogram[color.rgbKey, default: 0] += 1
            }
        }
        guard let backgroundKey = histogram.max(by: { $0.value < $1.value })?.key else {
            XCTFail("missing rendered button pixels: \(context)")
            return .missing
        }
        let background = NSColor(rgbKey: backgroundKey)
        let textMinX = Int((hitRect.midX - 72) * scaleX)
        let textMaxX = Int((hitRect.midX + 72) * scaleX)
        var bestContrast = 0.0
        var distinctTextPixels = 0
        for y in minY..<maxY {
            for x in textMinX..<textMaxX {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let ratio = color.contrastRatio(against: background)
                bestContrast = max(bestContrast, ratio)
                if ratio >= 3 { distinctTextPixels += 1 }
            }
        }
        return RenderedButtonMetrics(
            backgroundHex: background.rgbHex,
            textContrast: bestContrast,
            distinctTextPixels: distinctTextPixels
        )
    }

    private func writeEvidenceLogIfRequested(_ contents: String) throws {
        let data = Data(contents.utf8)
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.tab-separated-values"
        )
        attachment.name = "render-evidence.tsv"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["INCOMECLOCK_STAGE7_RENDER_DIR"] else { return }
        try data.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("render-evidence.tsv"),
            options: .atomic
        )
    }
}

@MainActor
private final class ThemeAppearanceProbe: ObservableObject {
    @Published var isDark = false
}

@MainActor
private struct ThemeAppearanceProbeView: View {
    @ObservedObject var probe: ThemeAppearanceProbe
    let businessStore: BusinessStore
    let themeStore: ThemeStore
    let profile: PanelPresentationProfile

    var body: some View {
        IncomePanelView(
            businessStore: businessStore,
            themeStore: themeStore,
            profile: profile,
            onOpenSettings: {},
            onHide: {}
        )
        .environment(\.colorScheme, probe.isDark ? .dark : .light)
    }
}

@MainActor
private final class ProductPanelInteractionHarness {
    enum HarnessError: Error {
        case primaryTrackingAreaNotFound
        case eventCreationFailed(String)
        case primaryFocusNotReached
        case bitmapUnavailable
    }

    private let coordinator = Stage5PanelKeyboardCoordinator()
    private let host: NSHostingView<IncomePanelView>
    private let panel: IncomePanel
    private let trackingArea: NSTrackingArea
    private let originalMouseLocation: CGPoint
    let hitRect: CGRect

    init(
        businessStore: BusinessStore,
        themeStore: ThemeStore,
        profile: PanelPresentationProfile
    ) throws {
        coordinator.configure(
            businessStore: businessStore,
            onOpenSettings: {},
            onHide: {}
        )
        host = NSHostingView(rootView: IncomePanelView(
            businessStore: businessStore,
            themeStore: themeStore,
            profile: profile,
            onOpenSettings: {},
            onHide: {},
            keyboardCoordinator: coordinator
        ))
        host.frame = CGRect(origin: .zero, size: profile.contentSize)
        panel = IncomePanel(
            contentRect: CGRect(
                origin: CGPoint(x: -10_000, y: -10_000),
                size: profile.contentSize
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.acceptsMouseMovedEvents = true
        panel.contentView = host
        panel.keyboardCommandHandler = { [weak coordinator] command in
            coordinator?.send(command)
        }
        guard let screen = NSScreen.main else {
            panel.contentView = nil
            throw HarnessError.eventCreationFailed("main-screen")
        }
        originalMouseLocation = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(
            x: screen.visibleFrame.minX + 24,
            y: screen.visibleFrame.minY + 24
        ))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        host.updateTrackingAreas()

        guard let candidate = Self.hostTrackingArea(in: host) else {
            FileHandle.standardError.write(Data(
                ("S7R003 tracking inventory:\n" + Self.trackingInventory(in: host) + "\n").utf8
            ))
            panel.orderOut(nil)
            panel.contentView = nil
            throw HarnessError.primaryTrackingAreaNotFound
        }
        trackingArea = candidate.area
        hitRect = CGRect(
            x: (profile.contentSize.width - ThemePanelLayout.primaryActionWidth) / 2,
            y: host.isFlipped
                ? profile.contentSize.height - 10 - ThemePanelLayout.primaryActionHeight
                : 10,
            width: ThemePanelLayout.primaryActionWidth,
            height: ThemePanelLayout.primaryActionHeight
        )
    }

    func transition(to state: ThemeControlState) async throws -> ProductInteractionObservation {
        let target = String(reflecting: type(of: host.hitTest(hitRect.center) ?? host))
        switch state {
        case .normal:
            try postMouseEvent(
                .mouseMoved,
                at: CGPoint(x: hitRect.minX - 4, y: hitRect.midY),
                button: .left
            )
            await settle()
            return observation(
                eventSequence: "NSEvent.mouseMoved(outside-primary-hitRect)>NSApplication.eventQueue>IncomePanel>NSHostingView",
                eventTarget: target
            )
        case .hover:
            try postMouseEvent(
                .mouseMoved,
                at: CGPoint(x: hitRect.minX - 4, y: hitRect.midY),
                button: .left
            )
            await settle()
            try postMouseEvent(.mouseMoved, at: hitRect.center, button: .left)
            await settle()
            return observation(
                eventSequence: "NSEvent.mouseMoved(outside)>NSEvent.mouseMoved(inside-primary-hitRect)>NSApplication.eventQueue>SwiftUI.onHover(true)",
                eventTarget: target
            )
        case .pressed:
            try postMouseEvent(.mouseMoved, at: hitRect.center, button: .left)
            await settle()
            try postMouseEvent(.leftMouseDown, at: hitRect.center, button: .left)
            await settle()
            return observation(
                eventSequence: "NSEvent.mouseMoved(inside)>NSEvent.leftMouseDown>NSApplication.eventQueue>SwiftUI.ButtonStyle.Configuration.isPressed",
                eventTarget: target
            )
        case .focused:
            try postMouseEvent(
                .mouseMoved,
                at: CGPoint(x: hitRect.minX - 4, y: hitRect.midY),
                button: .left
            )
            await settle()
            try postTabEvent()
            try postTabEvent()
            try postTabEvent()
            await settle()
            guard coordinator.semanticFocus == .primary else {
                throw HarnessError.primaryFocusNotReached
            }
            return observation(
                eventSequence: "NSEvent.keyDown/up(Tab)x3>NSApplication.eventQueue>IncomePanel.keyDown>Stage5PanelKeyboardCoordinator.primary>@FocusState.primary",
                eventTarget: target
            )
        case .disabled:
            return observation(eventSequence: "unsupported", eventTarget: target)
        }
    }

    func snapshot() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw HarnessError.bitmapUnavailable
        }
        host.cacheDisplay(in: host.bounds, to: representation)
        return representation
    }

    func finishInteraction(_ state: ThemeControlState) {
        if state == .pressed {
            try? postMouseEvent(
                .leftMouseUp,
                at: CGPoint(x: hitRect.minX - 8, y: hitRect.midY),
                button: .left
            )
        }
    }

    func close() {
        CGWarpMouseCursorPosition(Self.quartzPoint(fromAppKit: originalMouseLocation))
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func observation(
        eventSequence: String,
        eventTarget: String
    ) -> ProductInteractionObservation {
        let trackingOwner = trackingArea.owner
            .map { String(reflecting: type(of: $0)) } ?? "nil"
        return ProductInteractionObservation(
            productView: "IncomePanelView",
            window: "IncomePanel",
            eventSequence: eventSequence,
            eventTarget: eventTarget + ";trackingOwner=" + trackingOwner,
            semanticFocus: coordinator.semanticFocus == .primary ? "primary" : "none",
            hitRect: hitRect,
            hostIsFlipped: host.isFlipped
        )
    }

    private func postMouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        button: CGMouseButton
    ) throws {
        let appKitPoint = panel.convertPoint(toScreen: host.convert(point, to: nil))
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: host.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: type == .leftMouseDown ? 31 : (type == .leftMouseUp ? 32 : 33),
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else { throw HarnessError.eventCreationFailed("NSEvent.mouse") }
        CGWarpMouseCursorPosition(Self.quartzPoint(fromAppKit: appKitPoint))
        NSApp.postEvent(event, atStart: false)
        dispatchPendingApplicationEvents()
    }

    private func postTabEvent() throws {
        guard let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ) else { throw HarnessError.eventCreationFailed("NSEvent.Tab") }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        dispatchPendingApplicationEvents()
    }

    private func dispatchPendingApplicationEvents() {
        let deadline = Date().addingTimeInterval(0.05)
        while let event = NSApp.nextEvent(
            matching: .any,
            until: deadline,
            inMode: .default,
            dequeue: true
        ) {
            NSApp.sendEvent(event)
            if Date() >= deadline { break }
        }
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 25_000_000)
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private static func hostTrackingArea(
        in host: NSHostingView<IncomePanelView>
    ) -> (area: NSTrackingArea, ownerView: NSView)? {
        var candidates: [(NSTrackingArea, NSView, CGRect)] = []
        var queue = [host as NSView]
        while let view = queue.popLast() {
            queue.append(contentsOf: view.subviews)
            for area in view.trackingAreas
                where area.options.contains(.mouseEnteredAndExited) && area.options.contains(.mouseMoved) {
                let rect = host.convert(area.rect, from: view)
                if rect.intersects(host.bounds) {
                    candidates.append((area, view, rect))
                }
            }
        }
        return candidates.max(by: { $0.2.width * $0.2.height < $1.2.width * $1.2.height })
            .map { ($0.0, $0.1) }
    }

    private static func trackingInventory(in host: NSHostingView<IncomePanelView>) -> String {
        var rows: [String] = []
        var queue = [host as NSView]
        while let view = queue.popLast() {
            queue.append(contentsOf: view.subviews)
            for area in view.trackingAreas {
                rows.append(
                    "view=\(String(reflecting: type(of: view))) rect=\(host.convert(area.rect, from: view)) " +
                    "options=\(area.options.rawValue) owner=\(String(reflecting: type(of: area.owner as Any)))"
                )
            }
        }
        return rows.isEmpty ? "none" : rows.joined(separator: "\n")
    }

    private static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return CGPoint(x: point.x, y: desktopTop - point.y)
    }
}

private struct ProductInteractionObservation {
    let productView: String
    let window: String
    let eventSequence: String
    let eventTarget: String
    let semanticFocus: String
    let hitRect: CGRect
    let hostIsFlipped: Bool
}

private struct RenderedButtonMetrics {
    let backgroundHex: String
    let textContrast: Double
    let distinctTextPixels: Int

    static let missing = Self(
        backgroundHex: "missing",
        textContrast: 0,
        distinctTextPixels: 0
    )
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var tsvValue: String {
        [minX, minY, width, height].map { String(format: "%.2f", $0) }.joined(separator: ",")
    }
}

private extension NSColor {
    convenience init(themeHexForEvidence value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let raw = UInt64(hex, radix: 16) ?? 0
        let hasAlpha = hex.count == 8
        self.init(
            srgbRed: CGFloat((raw >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
            green: CGFloat((raw >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
            blue: CGFloat((raw >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
            alpha: hasAlpha ? CGFloat(raw & 0xff) / 255 : 1
        )
    }

    convenience init(rgbKey: UInt32) {
        self.init(
            srgbRed: CGFloat((rgbKey >> 16) & 0xff) / 255,
            green: CGFloat((rgbKey >> 8) & 0xff) / 255,
            blue: CGFloat(rgbKey & 0xff) / 255,
            alpha: 1
        )
    }

    var rgbKey: UInt32 {
        let color = usingColorSpace(.sRGB) ?? self
        let red = UInt32((color.redComponent * 255).rounded())
        let green = UInt32((color.greenComponent * 255).rounded())
        let blue = UInt32((color.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    var rgbHex: String { String(format: "#%06X", rgbKey) }

    func contrastRatio(against other: NSColor) -> Double {
        let left = relativeLuminance
        let right = other.relativeLuminance
        return (max(left, right) + 0.05) / (min(left, right) + 0.05)
    }

    private var relativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        func linear(_ value: CGFloat) -> Double {
            let component = Double(value)
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}

private struct FixedThemeCatalog: ThemeCatalogProviding {
    let snapshot: ThemeCatalogSnapshot

    func loadBuiltInThemes() async -> ThemeCatalogSnapshot { snapshot }
}

private actor ThemePreferencesRepositorySpy: ThemePreferencesRepository {
    private let initialLoad: RecordLoadResult<ThemePreferencesRecord>
    private let failSaves: Bool
    private var record: ThemePreferencesRecord?
    private var saves = 0
    private var recoveries = 0

    init(
        loadResult: RecordLoadResult<ThemePreferencesRecord>,
        failSaves: Bool = false
    ) {
        initialLoad = loadResult
        self.failSaves = failSaves
        if case let .loaded(record, _) = loadResult {
            self.record = record
        }
    }

    func loadThemePreferences() -> RecordLoadResult<ThemePreferencesRecord> { initialLoad }

    func saveThemePreferences(
        _ proposed: ThemePreferencesRecord,
        expectedRevision: RecordRevision?
    ) throws -> ThemePreferencesRecord {
        saves += 1
        if failSaves { throw PersistenceError.atomicWriteFailed }
        guard record?.revision == expectedRevision else {
            throw PersistenceError.revisionConflict(expected: expectedRevision, actual: record?.revision)
        }
        let committed = proposed.replacingRevision(.init(rawValue: (record?.revision.rawValue ?? 0) + 1))
        try committed.validated()
        record = committed
        return committed
    }

    func recoverThemePreferences(_ proposed: ThemePreferencesRecord) throws -> ThemePreferencesRecord {
        recoveries += 1
        if failSaves { throw PersistenceError.atomicWriteFailed }
        let committed = proposed.replacingRevision(.init(rawValue: 1))
        try committed.validated()
        record = committed
        return committed
    }

    func saveCount() -> Int { saves }
    func recoveryCount() -> Int { recoveries }
    func currentRecord() -> ThemePreferencesRecord? { record }
    func lastSavedThemeID() -> String? { record?.selectedThemeId }
}
