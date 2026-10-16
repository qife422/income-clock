import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import IncomeClock

final class PanelPlacementControllerTests: XCTestCase {
    private let profile = PanelPresentationProfileRegistry().standard
    private let controller = PanelPlacementController()
    private let main = PanelScreenDescriptor(
        displayUUID: "main-display",
        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 836),
        isMain: true
    )
    private let secondary = PanelScreenDescriptor(
        displayUUID: "secondary-display",
        frame: CGRect(x: 1_440, y: -200, width: 1_920, height: 1_080),
        visibleFrame: CGRect(x: 1_440, y: -200, width: 1_840, height: 1_080),
        isMain: false
    )

    func testStandardProfileOwnsAllStageFourGeometry() {
        XCTAssertEqual(profile.id, "standard.panel.320x190.v1")
        XCTAssertEqual(profile.contentSize, CGSize(width: 320, height: 190))
        XCTAssertEqual(profile.externalPresentationSize, CGSize(width: 320, height: 190))
        XCTAssertEqual(profile.contentSafeArea, CGRect(x: 12, y: 8, width: 296, height: 172))
        XCTAssertEqual(profile.primaryDragRegion, CGRect(x: 12, y: 8, width: 232, height: 28))
        XCTAssertEqual(profile.defaultEdgeOffset, 20)
    }

    func testFirstPlacementUsesMainVisibleFrameBottomRightWithTwentyPointMargins() {
        let placement = controller.defaultPlacement(on: main, profile: profile)

        XCTAssertEqual(placement.displayUUID, main.displayUUID)
        XCTAssertEqual(placement.snapCorner, .bottomRight)
        XCTAssertEqual(placement.xOffset, 20)
        XCTAssertEqual(placement.yOffset, 20)
        XCTAssertEqual(
            placement.constrainedFrame.cgRect,
            CGRect(x: 1_100, y: 44, width: 320, height: 190)
        )
    }

    func testDragSnapsToEachNearestCorner() throws {
        let cases: [(CGRect, PanelSnapCorner, CGPoint)] = [
            (CGRect(x: 100, y: 600, width: 320, height: 190), .topLeft, CGPoint(x: 20, y: 650)),
            (CGRect(x: 1_000, y: 600, width: 320, height: 190), .topRight, CGPoint(x: 1_100, y: 650)),
            (CGRect(x: 100, y: 60, width: 320, height: 190), .bottomLeft, CGPoint(x: 20, y: 44)),
            (CGRect(x: 1_000, y: 60, width: 320, height: 190), .bottomRight, CGPoint(x: 1_100, y: 44))
        ]

        for (dragged, expectedCorner, expectedOrigin) in cases {
            let placement = try XCTUnwrap(controller.snappedPlacement(
                for: dragged,
                screens: [main],
                mainScreen: main,
                profile: profile
            ))
            XCTAssertEqual(placement.snapCorner, expectedCorner)
            XCTAssertEqual(placement.constrainedFrame.cgRect.origin, expectedOrigin)
        }
    }

    func testSecondaryDisplayRestoreUsesStableUUIDAndSavedOffsets() throws {
        let saved = PanelPlacementRecord(
            displayUUID: secondary.displayUUID,
            snapCorner: .topLeft,
            xOffset: 35,
            yOffset: 45,
            constrainedFrame: .init(x: 0, y: 0, width: 320, height: 190)
        )

        let restored = try XCTUnwrap(controller.restoredPlacement(
            saved,
            screens: [main, secondary],
            mainScreen: main,
            profile: profile
        ))

        XCTAssertEqual(restored.displayUUID, secondary.displayUUID)
        XCTAssertEqual(restored.snapCorner, .topLeft)
        XCTAssertEqual(restored.constrainedFrame.cgRect, CGRect(x: 1_475, y: 645, width: 320, height: 190))
    }

    func testDisconnectedDisplayFallsBackToMainBottomRight() throws {
        let saved = PanelPlacementRecord(
            displayUUID: secondary.displayUUID,
            snapCorner: .topLeft,
            xOffset: 90,
            yOffset: 80,
            constrainedFrame: .init(x: 1_530, y: 600, width: 320, height: 190)
        )

        let restored = try XCTUnwrap(controller.restoredPlacement(
            saved,
            screens: [main],
            mainScreen: main,
            profile: profile
        ))

        XCTAssertEqual(restored.displayUUID, main.displayUUID)
        XCTAssertEqual(restored.snapCorner, .bottomRight)
        XCTAssertEqual(restored.constrainedFrame.cgRect, CGRect(x: 1_100, y: 44, width: 320, height: 190))
    }

    func testResolutionDockAndScaleChangesRecomputeAndClampAgainstVisibleFrame() throws {
        let changed = PanelScreenDescriptor(
            displayUUID: main.displayUUID,
            frame: CGRect(x: 0, y: 0, width: 900, height: 650),
            visibleFrame: CGRect(x: 76, y: 0, width: 824, height: 610),
            isMain: true
        )
        let saved = PanelPlacementRecord(
            displayUUID: main.displayUUID,
            snapCorner: .topRight,
            xOffset: 20,
            yOffset: 20,
            constrainedFrame: .init(x: 1_100, y: 650, width: 320, height: 190)
        )

        let restored = try XCTUnwrap(controller.restoredPlacement(
            saved,
            screens: [changed],
            mainScreen: changed,
            profile: profile
        ))

        XCTAssertEqual(restored.constrainedFrame.cgRect, CGRect(x: 560, y: 400, width: 320, height: 190))
        XCTAssertTrue(changed.visibleFrame.contains(restored.constrainedFrame.cgRect))
    }

    func testConstraintNeverResizesTheFixedStandardProfile() {
        let frame = CGRect(x: 700, y: 500, width: 320, height: 190)
        let unusuallySmallVisibleFrame = CGRect(x: 40, y: 30, width: 200, height: 100)

        let constrained = controller.constrainedFrame(frame, to: unusuallySmallVisibleFrame)

        XCTAssertEqual(constrained, CGRect(x: 40, y: 30, width: 320, height: 190))
    }

    func testSystemScreenProviderSelectsCoreGraphicsMainDisplayWithStableUUID() throws {
        let provider = SystemPanelScreenProvider()
        let mainScreen = try XCTUnwrap(provider.mainScreen)

        XCTAssertTrue(mainScreen.isMain)
        XCTAssertFalse(mainScreen.displayUUID.isEmpty)
        XCTAssertEqual(provider.screens.filter(\.isMain).count, 1)
        XCTAssertEqual(
            provider.screens.first(where: \.isMain)?.displayUUID,
            mainScreen.displayUUID
        )
    }
}

@MainActor
final class PanelControllerTests: XCTestCase {
    private var mainScreen: PanelScreenDescriptor {
        PanelScreenDescriptor(
            displayUUID: "main-display",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 836),
            isMain: true
        )
    }

    func testResetDefaultPlacementPersistsBeforeMovingAndFailureKeepsFrame() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current))
        let controller = try makeController(repository: repository)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        panel.setFrameOrigin(CGPoint(x: 200, y: 300))
        controller.finishDragging()
        await controller.waitForPendingPersistence()
        let previousFrame = panel.frame
        let previousSettings = await repository.currentSettings()
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        let failed = await controller.resetToDefaultPlacement()
        XCTAssertFalse(failed)
        XCTAssertEqual(panel.frame, previousFrame)
        let preserved = await repository.currentSettings()
        XCTAssertEqual(preserved, previousSettings)
        let succeeded = await controller.resetToDefaultPlacement()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 1_100, y: 44))
        let committed = await repository.currentSettings()
        XCTAssertEqual(committed?.panelPlacement?.snapCorner, .bottomRight)
        XCTAssertEqual(committed?.panelPlacement?.constrainedFrame.cgRect, panel.frame)
    }

    func testPanelHarnessRestoresWindowBehaviorWithoutShowingHiddenPanel() async throws {
        let settings = ApplicationTestSupport.proposedSettings(
            notificationsEnabled: true,
            alwaysOnTop: false,
            lockPanelPosition: true,
            hideInFullScreen: false,
            launchAtLogin: true,
            panelVisible: false,
            updatedAtMs: 10
        ).replacingRevision(.init(rawValue: 7))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current)
        )
        let controller = try makeController(repository: repository)

        let shouldShow = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)

        XCTAssertFalse(shouldShow)
        XCTAssertEqual(panel.contentLayoutRect.size, CGSize(width: 320, height: 190))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isResizable)
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testDefaultFullScreenPolicyOmitsAuxiliaryBehaviorAndUsesFloatingLevel() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let controller = try makeController(repository: repository)

        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)

        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testCloseMeansHideAndPersistsVisibilityWithoutReleasingPanel() async throws {
        let original = ApplicationTestSupport.committedSettings(wageCents: 54_321)
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(original, migration: .current)
        )
        let controller = try makeController(repository: repository)
        var observedVisibility: Bool?
        controller.setVisibilityChangeHandler { observedVisibility = $0 }
        _ = await controller.restore()
        controller.show(persist: false, focus: false)
        let panel = try XCTUnwrap(controller.windowForTesting)

        XCTAssertFalse(controller.windowShouldClose(panel))
        await controller.waitForPendingPersistence()
        let savedSettings = await repository.currentSettings()
        let committed = try XCTUnwrap(savedSettings)

        XCTAssertEqual(observedVisibility, false)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertFalse(committed.panelVisible)
        XCTAssertEqual(committed.dailyWageCents, original.dailyWageCents)
        XCTAssertEqual(committed.workStartMinuteOfDay, original.workStartMinuteOfDay)
        XCTAssertEqual(committed.workEndMinuteOfDay, original.workEndMinuteOfDay)
        XCTAssertEqual(committed.notificationsEnabled, original.notificationsEnabled)
        XCTAssertEqual(committed.revision, .init(rawValue: 2))
    }

    func testRapidVisibilityCommandsAreSerializedAndLastCommandWins() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let controller = try makeController(repository: repository)
        _ = await controller.restore()

        controller.hide(persist: true)
        controller.show(persist: true)
        controller.hide(persist: true)
        await controller.waitForPendingPersistence()

        let savedSettings = await repository.currentSettings()
        let committed = try XCTUnwrap(savedSettings)
        let saveCount = await repository.settingsSaveCount
        XCTAssertFalse(committed.panelVisible)
        XCTAssertEqual(committed.revision, .init(rawValue: 4))
        XCTAssertEqual(saveCount, 3)
    }

    func testDragToSecondarySnapsAndPersistsPlacementOnly() async throws {
        let secondary = PanelScreenDescriptor(
            displayUUID: "secondary-display",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_040),
            isMain: false
        )
        let screens = MutablePanelScreenProvider(screens: [mainScreen, secondary])
        let original = ApplicationTestSupport.committedSettings(wageCents: 87_654)
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(original, migration: .current)
        )
        let controller = try makeController(repository: repository, screens: screens)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        panel.setFrameOrigin(CGPoint(x: 2_900, y: 100))

        controller.finishDragging()
        await controller.waitForPendingPersistence()
        let savedSettings = await repository.currentSettings()
        let committed = try XCTUnwrap(savedSettings)

        XCTAssertEqual(committed.panelPlacement?.displayUUID, secondary.displayUUID)
        XCTAssertEqual(committed.panelPlacement?.snapCorner, .bottomRight)
        XCTAssertEqual(committed.panelPlacement?.constrainedFrame.cgRect, CGRect(x: 3_020, y: 20, width: 320, height: 190))
        XCTAssertEqual(committed.dailyWageCents, original.dailyWageCents)
        XCTAssertEqual(committed.panelVisible, original.panelVisible)
    }

    func testScreenParameterChangeFallsBackAfterSecondaryDisconnect() async throws {
        let secondary = PanelScreenDescriptor(
            displayUUID: "secondary-display",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_040),
            isMain: false
        )
        let placement = PanelPlacementRecord(
            displayUUID: secondary.displayUUID,
            snapCorner: .topLeft,
            xOffset: 20,
            yOffset: 20,
            constrainedFrame: .init(x: 1_460, y: 830, width: 320, height: 190)
        )
        let settings = ApplicationTestSupport.proposedSettings(
            panelPlacement: placement
        ).replacingRevision(.init(rawValue: 2))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current)
        )
        let screens = MutablePanelScreenProvider(screens: [mainScreen, secondary])
        let notificationCenter = NotificationCenter()
        let controller = try makeController(
            repository: repository,
            screens: screens,
            notificationCenter: notificationCenter
        )
        _ = await controller.restore()
        XCTAssertEqual(controller.windowForTesting?.frame.origin, CGPoint(x: 1_460, y: 830))

        screens.screens = [mainScreen]
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await controller.waitForPendingPersistence()

        XCTAssertEqual(controller.windowForTesting?.frame, CGRect(x: 1_100, y: 44, width: 320, height: 190))
        let savedSettings = await repository.currentSettings()
        XCTAssertEqual(savedSettings?.panelPlacement?.displayUUID, mainScreen.displayUUID)
        XCTAssertEqual(savedSettings?.panelPlacement?.snapCorner, .bottomRight)
    }

    func testSpaceAndWakeNotificationsReapplyBehaviorAndScreenConstraints() async throws {
        let changedMain = PanelScreenDescriptor(
            displayUUID: mainScreen.displayUUID,
            frame: CGRect(x: 0, y: 0, width: 900, height: 650),
            visibleFrame: CGRect(x: 76, y: 0, width: 824, height: 610),
            isMain: true
        )
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let screens = MutablePanelScreenProvider(screens: [mainScreen])
        let workspaceCenter = NotificationCenter()
        let controller = try makeController(
            repository: repository,
            screens: screens,
            workspaceNotificationCenter: workspaceCenter
        )
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        panel.collectionBehavior = []

        workspaceCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))

        screens.screens = [changedMain]
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await controller.waitForPendingPersistence()
        let savedAfterWake = await repository.currentSettings()
        XCTAssertEqual(panel.frame, CGRect(x: 560, y: 20, width: 320, height: 190))
        XCTAssertEqual(
            savedAfterWake?.panelPlacement?.constrainedFrame.cgRect,
            panel.frame
        )
    }

    func testWindowDidMoveDebounceSnapsAndPersistsThroughDelegatePath() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let controller = try makeController(repository: repository)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        panel.setFrameOrigin(CGPoint(x: 100, y: 600))

        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        try await Task.sleep(nanoseconds: 250_000_000)
        await controller.waitForPendingPersistence()

        let saved = await repository.currentSettings()
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 20, y: 650))
        XCTAssertEqual(saved?.panelPlacement?.snapCorner, .topLeft)
    }

    func testLockedPanelMoveDoesNotSnapOrPersistPlacement() async throws {
        let settings = ApplicationTestSupport.proposedSettings(
            lockPanelPosition: true
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current)
        )
        let controller = try makeController(repository: repository)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        panel.setFrameOrigin(CGPoint(x: 100, y: 600))

        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        controller.finishDragging()
        try await Task.sleep(nanoseconds: 250_000_000)
        await controller.waitForPendingPersistence()

        let saveCount = await repository.settingsSaveCount
        let saved = await repository.currentSettings()
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 100, y: 600))
        XCTAssertEqual(saveCount, 0)
        XCTAssertNil(saved?.panelPlacement)
    }

    func testOrdinaryShowDoesNotTakeKeyInXCTestHost() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let controller = try makeController(repository: repository)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)

        controller.show(persist: false, focus: false)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(panel.canBecomeKey)
    }

    func testPanelRoutesOnlyPlainTabAndActivationKeysBeforeSwiftUIConsumesTheEvent() throws {
        let panel = IncomePanel(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var reverseValues: [Bool] = []
        let token = NotificationCenter.default.addObserver(
            forName: .incomePanelAdvanceKeyboardFocus,
            object: panel,
            queue: nil
        ) { note in
            reverseValues.append(note.userInfo?["reverse"] as? Bool == true)
        }
        var activationCount = 0
        let activationToken = NotificationCenter.default.addObserver(
            forName: .incomePanelActivateKeyboardFocus,
            object: panel,
            queue: nil
        ) { _ in activationCount += 1 }
        var cancellationCount = 0
        let cancellationToken = NotificationCenter.default.addObserver(
            forName: .incomePanelCancelConfirmation,
            object: panel,
            queue: nil
        ) { _ in cancellationCount += 1 }
        defer {
            NotificationCenter.default.removeObserver(token)
            NotificationCenter.default.removeObserver(activationToken)
            NotificationCenter.default.removeObserver(cancellationToken)
        }

        func event(
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags = [],
            characters: String
        ) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        let forward = try event(keyCode: 48, characters: "\t")
        let reverse = try event(keyCode: 48, modifiers: [.shift], characters: "\t")
        let optionTab = try event(keyCode: 48, modifiers: [.option], characters: "\t")
        let controlTab = try event(keyCode: 48, modifiers: [.control], characters: "\t")
        let commandTab = try event(keyCode: 48, modifiers: [.command], characters: "\t")
        let space = try event(keyCode: 49, characters: " ")
        let enter = try event(keyCode: 36, characters: "\r")
        let escape = try event(keyCode: 53, characters: "\u{1b}")

        panel.sendEvent(forward)
        panel.sendEvent(reverse)
        panel.sendEvent(space)
        panel.sendEvent(enter)
        panel.sendEvent(escape)

        XCTAssertEqual(reverseValues, [false, true])
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNil(IncomePanel.keyboardCommand(for: optionTab))
        XCTAssertNil(IncomePanel.keyboardCommand(for: controlTab))
        XCTAssertNil(IncomePanel.keyboardCommand(for: commandTab))
        XCTAssertEqual(IncomePanel.keyboardCommand(for: space), .activateFocus)
        XCTAssertEqual(IncomePanel.keyboardCommand(for: enter), .activateFocus)
        XCTAssertEqual(IncomePanel.keyboardCommand(for: escape), .cancelConfirmation)
    }

    func testImmediateHideCancelsDeferredFocusedShow() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let controller = try makeController(repository: repository)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)

        controller.show(persist: false, focus: true)
        controller.hide(persist: false)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testEnvironmentRestoresSavedHiddenVisibilityBeforeAnyShow() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let panel = PanelControllerSpy()
        panel.restoredVisibility = false
        let environment = AppEnvironment(businessStore: store, panelController: panel)

        await environment.start()

        XCTAssertEqual(panel.restoreCount, 1)
        XCTAssertEqual(panel.showCount, 0)
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertFalse(environment.isPanelVisible)
    }

    func testShortcutPanelToggleRequestsFocusAndPersistsVisibility() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let panel = PanelControllerSpy()
        panel.restoredVisibility = false
        let environment = AppEnvironment(businessStore: store, panelController: panel)
        await environment.start()

        environment.togglePanelFromShortcut()

        XCTAssertEqual(panel.showCount, 1)
        XCTAssertEqual(panel.lastShowPersist, true)
        XCTAssertEqual(panel.lastShowFocus, true)
        XCTAssertTrue(environment.isPanelVisible)
    }

    func testMenuBarPanelTogglePersistsWithoutRequestingFocus() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let panel = PanelControllerSpy()
        panel.restoredVisibility = false
        let environment = AppEnvironment(businessStore: store, panelController: panel)
        await environment.start()

        environment.togglePanelFromMenuBar()

        XCTAssertEqual(panel.showCount, 1)
        XCTAssertEqual(panel.lastShowPersist, true)
        XCTAssertEqual(panel.lastShowFocus, false)
        XCTAssertTrue(environment.isPanelVisible)
    }

    func testVisibilityAndPlacementSurviveRealRepositoryRestart() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let secondary = PanelScreenDescriptor(
            displayUUID: "secondary-display",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_040),
            isMain: false
        )
        let screens = MutablePanelScreenProvider(screens: [mainScreen, secondary])
        let firstRepository = RecordRepositoryActor(paths: .init(root: root))
        _ = try await firstRepository.saveSettings(
            ApplicationTestSupport.proposedSettings(wageCents: 76_543),
            expectedRevision: nil
        )
        let firstController = try makeController(
            repository: firstRepository,
            screens: screens
        )
        _ = await firstController.restore()
        let firstPanel = try XCTUnwrap(firstController.windowForTesting)
        firstPanel.setFrameOrigin(CGPoint(x: 2_900, y: 100))
        firstController.finishDragging()
        firstController.hide(persist: true)
        await firstController.waitForPendingPersistence()

        let restartedRepository = RecordRepositoryActor(paths: .init(root: root))
        let restartedController = try makeController(
            repository: restartedRepository,
            screens: screens
        )
        let shouldShow = await restartedController.restore()

        XCTAssertFalse(shouldShow)
        XCTAssertEqual(
            restartedController.windowForTesting?.frame,
            CGRect(x: 3_020, y: 20, width: 320, height: 190)
        )
        let loaded = await restartedRepository.loadSettings()
        guard case let .loaded(settings, _) = loaded else {
            return XCTFail("Expected the panel settings to survive restart")
        }
        XCTAssertEqual(settings.dailyWageCents, 76_543)
        XCTAssertEqual(settings.panelPlacement?.displayUUID, secondary.displayUUID)
        XCTAssertFalse(settings.panelVisible)
        XCTAssertEqual(settings.revision, .init(rawValue: 3))
    }

    func testMissingSettingsPanelPreferencesSurviveRestartAndMergeIntoFirstSave() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferenceURL = root.appendingPathComponent("pending-panel.json")
        let secondary = PanelScreenDescriptor(
            displayUUID: "secondary-display",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_040),
            isMain: false
        )
        let screens = MutablePanelScreenProvider(screens: [mainScreen, secondary])
        let firstRawRepository = RecordRepositoryActor(paths: .init(root: root))
        let firstCoordinator = PanelSettingsCoordinator(
            repository: firstRawRepository,
            preferenceStore: FilePanelPreferenceStore(url: preferenceURL)
        )
        let firstController = try makeController(
            repository: firstCoordinator,
            panelRepository: firstCoordinator,
            screens: screens
        )
        let firstShouldShow = await firstController.restore()
        XCTAssertTrue(firstShouldShow)
        let panel = try XCTUnwrap(firstController.windowForTesting)
        panel.setFrameOrigin(CGPoint(x: 2_900, y: 100))
        firstController.finishDragging()
        firstController.hide(persist: true)
        await firstController.waitForPendingPersistence()
        guard case .missing = await firstRawRepository.loadSettings() else {
            return XCTFail("Panel preferences must not synthesize work-rule Settings")
        }

        let restartedRawRepository = RecordRepositoryActor(paths: .init(root: root))
        let restartedCoordinator = PanelSettingsCoordinator(
            repository: restartedRawRepository,
            preferenceStore: FilePanelPreferenceStore(url: preferenceURL)
        )
        let restartedController = try makeController(
            repository: restartedCoordinator,
            panelRepository: restartedCoordinator,
            screens: screens
        )
        let restartedShouldShow = await restartedController.restore()
        XCTAssertFalse(restartedShouldShow)
        XCTAssertEqual(
            restartedController.windowForTesting?.frame,
            CGRect(x: 3_020, y: 20, width: 320, height: 190)
        )

        _ = try await restartedCoordinator.saveSettings(
            ApplicationTestSupport.proposedSettings(wageCents: 76_543),
            expectedRevision: nil
        )
        guard case let .loaded(settings, _) = await restartedRawRepository.loadSettings() else {
            return XCTFail("Expected first Settings save")
        }
        XCTAssertEqual(settings.dailyWageCents, 76_543)
        XCTAssertFalse(settings.panelVisible)
        XCTAssertEqual(settings.panelPlacement?.displayUUID, secondary.displayUUID)
        XCTAssertEqual(settings.revision, .init(rawValue: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferenceURL.path))
    }

    func testHeldFirstSettingsSaveCannotLoseConcurrentMissingPanelMutation() async throws {
        let repository = BusinessRecordRepositorySpy()
        let preferences = EphemeralPanelPreferenceStore()
        let coordinator = PanelSettingsCoordinator(
            repository: repository,
            preferenceStore: preferences
        )
        await repository.holdNextSettingsSave()

        let firstSave = Task {
            try await coordinator.saveSettings(
                ApplicationTestSupport.proposedSettings(wageCents: 81_234),
                expectedRevision: nil
            )
        }
        await repository.waitUntilSettingsSaveIsHeld()

        let mutationStarted = expectation(description: "Panel mutation task started")
        let panelMutation = Task {
            mutationStarted.fulfill()
            return try await coordinator.persistPanelMutation(
                .visibility(false),
                updatedAtMs: 300
            )
        }
        await fulfillment(of: [mutationStarted], timeout: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        await repository.resumeHeldSettingsSave()

        _ = try await firstSave.value
        _ = try await panelMutation.value
        let current = await repository.currentSettings()
        let saved = try XCTUnwrap(current)
        XCTAssertEqual(saved.dailyWageCents, 81_234)
        XCTAssertFalse(saved.panelVisible)
        XCTAssertEqual(saved.revision, .init(rawValue: 2))
        let remainingPreferences = await preferences.load()
        XCTAssertNil(remainingPreferences)
    }

    func testHeldMissingPanelMutationCannotBeOrphanedByConcurrentFirstSettingsSave() async throws {
        let repository = BusinessRecordRepositorySpy()
        let preferences = HoldingPanelPreferenceStore()
        let coordinator = PanelSettingsCoordinator(
            repository: repository,
            preferenceStore: preferences
        )
        await preferences.holdNextLoad()

        let panelMutation = Task {
            try await coordinator.persistPanelMutation(
                .visibility(false),
                updatedAtMs: 300
            )
        }
        await preferences.waitUntilLoadIsHeld()

        let firstSaveStarted = expectation(description: "First Settings save task started")
        let firstSave = Task {
            firstSaveStarted.fulfill()
            return try await coordinator.saveSettings(
                ApplicationTestSupport.proposedSettings(wageCents: 91_234),
                expectedRevision: nil
            )
        }
        await fulfillment(of: [firstSaveStarted], timeout: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        await preferences.resumeHeldLoad()

        _ = try await panelMutation.value
        _ = try await firstSave.value
        let current = await repository.currentSettings()
        let saved = try XCTUnwrap(current)
        XCTAssertEqual(saved.dailyWageCents, 91_234)
        XCTAssertFalse(saved.panelVisible)
        XCTAssertEqual(saved.revision, .init(rawValue: 1))
        let remainingPreferences = await preferences.load()
        XCTAssertNil(remainingPreferences)
    }

    func testRevisionConflictRetriesOnceAndPreservesConcurrentNonPanelFields() async throws {
        let original = ApplicationTestSupport.committedSettings(wageCents: 30_000)
        let concurrent = ApplicationTestSupport.proposedSettings(
            wageCents: 88_888,
            notificationsEnabled: true,
            updatedAtMs: 200
        ).replacingRevision(.init(rawValue: 2))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(original, migration: .current)
        )
        await repository.failNextSettingsSave(
            with: .revisionConflict(expected: original.revision, actual: concurrent.revision),
            thenReplaceSettingsWith: concurrent
        )
        let controller = try makeController(repository: repository)
        _ = await controller.restore()

        controller.hide(persist: true)
        await controller.waitForPendingPersistence()

        let current = await repository.currentSettings()
        let saveCount = await repository.settingsSaveCount
        let saved = try XCTUnwrap(current)
        XCTAssertFalse(saved.panelVisible)
        XCTAssertEqual(saved.dailyWageCents, concurrent.dailyWageCents)
        XCTAssertTrue(saved.notificationsEnabled)
        XCTAssertEqual(saved.revision, .init(rawValue: 3))
        XCTAssertEqual(saveCount, 2)
        XCTAssertNil(controller.lastRuntimeError)
    }

    func testRepeatedRevisionConflictFailsClosedWithoutChangingRecord() async throws {
        let original = ApplicationTestSupport.committedSettings(wageCents: 42_000)
        let conflict = PersistenceError.revisionConflict(
            expected: original.revision,
            actual: .init(rawValue: 2)
        )
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(original, migration: .current)
        )
        await repository.failSettingsSaves(with: [conflict, conflict])
        let controller = try makeController(repository: repository)
        _ = await controller.restore()

        controller.hide(persist: true)
        await controller.waitForPendingPersistence()

        let saved = await repository.currentSettings()
        let saveCount = await repository.settingsSaveCount
        XCTAssertEqual(saved, original)
        XCTAssertEqual(saveCount, 2)
        XCTAssertEqual(controller.lastRuntimeError, .persistence(conflict))
    }

    func testAtomicWriteFailureLeavesOriginalRecordAndReportsError() async throws {
        let original = ApplicationTestSupport.committedSettings(wageCents: 42_000)
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(original, migration: .current)
        )
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        let controller = try makeController(repository: repository)
        _ = await controller.restore()

        controller.hide(persist: true)
        await controller.waitForPendingPersistence()

        let saved = await repository.currentSettings()
        let saveCount = await repository.settingsSaveCount
        XCTAssertEqual(saved, original)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(controller.lastRuntimeError, .persistence(.atomicWriteFailed))
    }

    func testDamagedSettingsAreNotOverwrittenByPanelMutation() async throws {
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        let repository = BusinessRecordRepositorySpy(settings: .damaged(damage))
        let controller = try makeController(repository: repository)

        _ = await controller.restore()
        controller.hide(persist: true)
        await controller.waitForPendingPersistence()

        let saveCount = await repository.settingsSaveCount
        let saved = await repository.currentSettings()
        XCTAssertEqual(saveCount, 0)
        XCTAssertNil(saved)
        XCTAssertEqual(controller.lastRuntimeError, .settingsDamaged(.decodingFailed))
    }

    func testRapidVisibilityAndPlacementInterleaveKeepsLatestPanelStateAndOtherFields() async throws {
        let secondary = PanelScreenDescriptor(
            displayUUID: "secondary-display",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_040),
            isMain: false
        )
        let screens = MutablePanelScreenProvider(screens: [mainScreen, secondary])
        let original = ApplicationTestSupport.proposedSettings(
            wageCents: 65_432,
            notificationsEnabled: true
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(original, migration: .current)
        )
        let controller = try makeController(repository: repository, screens: screens)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)

        controller.hide(persist: true)
        panel.setFrameOrigin(CGPoint(x: 2_900, y: 100))
        controller.finishDragging()
        controller.show(persist: true, focus: false)
        await controller.waitForPendingPersistence()

        let current = await repository.currentSettings()
        let saved = try XCTUnwrap(current)
        XCTAssertTrue(saved.panelVisible)
        XCTAssertEqual(saved.panelPlacement?.displayUUID, secondary.displayUUID)
        XCTAssertEqual(saved.dailyWageCents, original.dailyWageCents)
        XCTAssertTrue(saved.notificationsEnabled)
        XCTAssertEqual(saved.revision, .init(rawValue: 4))
        XCTAssertNil(controller.lastRuntimeError)
    }

    func testPanelBehaviorTogglesPersistAndApplyOnlyAfterSuccessfulCommit() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let controller = try makeController(repository: repository)
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)

        let topCommitted = await controller.setAlwaysOnTop(false)
        let lockCommitted = await controller.setLockPanelPosition(true)
        let fullScreenCommitted = await controller.setHideInFullScreen(false)
        let stored = await repository.currentSettings()
        let committed = try XCTUnwrap(stored)

        XCTAssertTrue(topCommitted)
        XCTAssertTrue(lockCommitted)
        XCTAssertTrue(fullScreenCommitted)
        XCTAssertEqual(controller.runtimePreferences(), .init(
            alwaysOnTop: false, lockPanelPosition: true, hideInFullScreen: false
        ))
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(committed.alwaysOnTop)
        XCTAssertTrue(committed.lockPanelPosition)
        XCTAssertFalse(committed.hideInFullScreen)
        XCTAssertEqual(committed.revision, .init(rawValue: 4))
    }

    private func makeController(
        repository: any BusinessRecordRepository,
        screens: MutablePanelScreenProvider? = nil,
        notificationCenter: NotificationCenter = NotificationCenter(),
        workspaceNotificationCenter: NotificationCenter = NotificationCenter()
    ) throws -> PanelController {
        let coordinator = PanelSettingsCoordinator(
            repository: repository,
            preferenceStore: EphemeralPanelPreferenceStore()
        )
        return try makeController(
            repository: coordinator,
            panelRepository: coordinator,
            screens: screens,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
    }

    private func makeController(
        repository: any BusinessRecordRepository,
        panelRepository: any PanelSettingsPersisting,
        screens: MutablePanelScreenProvider? = nil,
        notificationCenter: NotificationCenter = NotificationCenter(),
        workspaceNotificationCenter: NotificationCenter = NotificationCenter()
    ) throws -> PanelController {
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        return PanelController(
            businessStore: store,
            repository: panelRepository,
            screenProvider: screens ?? MutablePanelScreenProvider(screens: [mainScreen]),
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            nowMilliseconds: { 123_456 }
        )
    }

}

@MainActor
final class Stage5PresentationTests: XCTestCase {
    func testSevenBusinessStatesHaveDeterministicCopyPrecisionAndActions() throws {
        let cases: [(WorkdayState, String, String?, Stage5PanelPresentation.Action)] = [
            (.unconfigured, "待完成设置", "¥0.00", .openSettings),
            (.ready, "今日未打卡", "¥0.00", .clockIn(enabled: true)),
            (.clockedInWaiting, "已打卡 · 等待开工", "¥0.000", .clockOut),
            (.earning, "计薪中", "¥123.456", .clockOut),
            (.awaitingClockOut, "计薪已停止", "¥123.46", .clockOut),
            (.completed, "今日已完成", "¥123.46", .none),
            (.recoveryRequired, "记录需要恢复", nil, .resetToday)
        ]

        for (state, status, amount, action) in cases {
            let presentation = Stage5PanelPresentation.make(from: try viewState(state))
            XCTAssertEqual(presentation.status, status)
            XCTAssertEqual(presentation.amount, amount)
            XCTAssertEqual(presentation.action, action)
        }
    }

    func testOldWorkdaySurfacesDateAndStartTodayOnlyAfterCompletion() throws {
        let awaiting = Stage5PanelPresentation.make(from: try viewState(
            .awaitingClockOut, previous: true, canStartToday: false
        ))
        let completed = Stage5PanelPresentation.make(from: try viewState(
            .completed, previous: true, canStartToday: true
        ))

        XCTAssertTrue(awaiting.status.contains("2026-08-17"))
        XCTAssertEqual(awaiting.action, .clockOut)
        XCTAssertTrue(completed.status.contains("2026-08-17"))
        XCTAssertEqual(completed.action, .startToday)
    }

    func testKeyboardFocusOrderCoversAllStatesWithoutCompletedGhostSlot() throws {
        let ordinaryStates: [WorkdayState] = [
            .unconfigured, .ready, .clockedInWaiting, .earning, .awaitingClockOut,
            .recoveryRequired
        ]
        for state in ordinaryStates {
            let presentation = Stage5PanelPresentation.make(from: try viewState(state))
            XCTAssertEqual(
                Stage5PanelKeyboardModel.focusOrder(
                    confirmationPresented: false,
                    hasUsablePrimaryAction: Stage5PanelKeyboardModel.hasUsablePrimaryAction(
                        in: presentation
                    )
                ),
                [.settings, .hide, .primary],
                "Expected a real primary action for \(state)"
            )
        }

        let completed = Stage5PanelPresentation.make(from: try viewState(.completed))
        XCTAssertFalse(Stage5PanelKeyboardModel.hasUsablePrimaryAction(in: completed))
        XCTAssertEqual(
            Stage5PanelKeyboardModel.focusOrder(
                confirmationPresented: false,
                hasUsablePrimaryAction: false
            ),
            [.settings, .hide]
        )
        XCTAssertEqual(
            Stage5PanelKeyboardModel.focusOrder(
                confirmationPresented: true,
                hasUsablePrimaryAction: true
            ),
            [.cancel, .confirm]
        )
        XCTAssertEqual(
            Stage5PanelKeyboardModel.focusOrder(
                confirmationPresented: false,
                hasUsablePrimaryAction: true
            ),
            [.settings, .hide, .primary],
            "Blocking damaged-Settings and recovery surfaces expose a real recovery action"
        )

        let namedSurfaceMatrix: [(String, Bool, Bool, [Stage5PanelKeyboardFocus])] = [
            ("normal", false, true, [.settings, .hide, .primary]),
            ("unconfigured", false, true, [.settings, .hide, .primary]),
            ("confirmation", true, true, [.cancel, .confirm]),
            ("damaged", false, true, [.settings, .hide, .primary]),
            ("recovery", false, true, [.settings, .hide, .primary]),
            ("completed", false, false, [.settings, .hide])
        ]
        for (surface, confirming, primary, expected) in namedSurfaceMatrix {
            XCTAssertEqual(
                Stage5PanelKeyboardModel.focusOrder(
                    confirmationPresented: confirming,
                    hasUsablePrimaryAction: primary
                ),
                expected,
                "Unexpected semantic focus order for \(surface)"
            )
        }
    }

    func testCompletedPresentationUsesExactSettlementLabelsAndTwoDecimalBlessingAmount() throws {
        let presentation = Stage5PanelPresentation.make(from: try viewState(.completed))

        XCTAssertEqual(presentation.amount, "¥123.46")
        XCTAssertEqual(presentation.supportText, "计薪时长 03:47:18")
        XCTAssertTrue(presentation.durationText.contains("上班 10:10:00"))
        XCTAssertTrue(presentation.durationText.contains("下班 13:57:18"))
        XCTAssertEqual(
            "今日辛苦啦，喜提 \(presentation.amount ?? "")，今天的努力已经成功变现。",
            "今日辛苦啦，喜提 ¥123.46，今天的努力已经成功变现。"
        )
    }

    func testKeyboardCoordinatorActivatesSettingsHidePrimaryCancelAndConfirm() async throws {
        let repository = BusinessRecordRepositorySpy(settings: .missing, today: .missing)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        await store.restore()
        var settingsActivations = 0
        var hideActivations = 0
        let coordinator = Stage5PanelKeyboardCoordinator()
        coordinator.configure(
            businessStore: store,
            onOpenSettings: { settingsActivations += 1 },
            onHide: { hideActivations += 1 }
        )

        coordinator.requestInitialFocus()
        XCTAssertEqual(coordinator.semanticFocus, .settings)
        coordinator.send(.activateFocus)
        XCTAssertEqual(settingsActivations, 1)

        coordinator.requestInitialFocus()
        coordinator.send(.advanceFocus(reverse: false))
        XCTAssertEqual(coordinator.semanticFocus, .hide)
        coordinator.send(.activateFocus)
        XCTAssertEqual(hideActivations, 1)

        let saveOutcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .system
        )
        XCTAssertEqual(saveOutcome, .committed)
        coordinator.requestInitialFocus()
        coordinator.send(.advanceFocus(reverse: false))
        coordinator.send(.advanceFocus(reverse: false))
        XCTAssertEqual(coordinator.semanticFocus, .primary)
        coordinator.send(.activateFocus)
        try await waitUntil {
            guard let state = store.viewState?.state else { return false }
            return [.clockedInWaiting, .earning, .awaitingClockOut].contains(state)
        }

        let firstConfirmation = await store.send(.requestClockOut, source: .system)
        XCTAssertEqual(firstConfirmation, .confirmationPresented)
        coordinator.requestInitialFocus()
        XCTAssertEqual(coordinator.semanticFocus, .cancel)
        coordinator.send(.cancelConfirmation)
        try await waitUntil { store.confirmation == nil }

        let secondConfirmation = await store.send(.requestClockOut, source: .system)
        XCTAssertEqual(secondConfirmation, .confirmationPresented)
        coordinator.requestInitialFocus()
        coordinator.send(.advanceFocus(reverse: false))
        XCTAssertEqual(coordinator.semanticFocus, .confirm)
        coordinator.send(.activateFocus)
        try await waitUntil { store.viewState?.state == .completed }
    }

    func testAmountFormattingHandlesCarryBoundariesAndNeverDropsBelowTwentySixPoints() {
        XCTAssertEqual(Stage5AmountFormatter.string(minorUnits: 999_999, fractionDigits: 3), "¥999.999")
        XCTAssertEqual(Stage5AmountFormatter.string(minorUnits: 1_000_000, fractionDigits: 3), "¥1,000.000")
        XCTAssertEqual(Stage5AmountFormatter.string(minorUnits: 12_009, fractionDigits: 3), "¥12.009")
        XCTAssertEqual(Stage5AmountFormatter.string(minorUnits: 12_010, fractionDigits: 3), "¥12.010")
        XCTAssertEqual(Stage5AmountFormatter.string(minorUnits: 99_999, fractionDigits: 3), "¥99.999")
        XCTAssertEqual(Stage5AmountFormatter.string(minorUnits: 100_000, fractionDigits: 3), "¥100.000")
        XCTAssertGreaterThanOrEqual(Stage5AmountFormatter.fontSize(for: "¥999,999.99"), 26)
        XCTAssertGreaterThanOrEqual(Stage5AmountFormatter.fontSize(for: "¥999,999,999.99"), 26)
    }

    func testNativeOdometerAppliesExactABPresetsDirectionsAndAtomicCarries() throws {
        let font = Stage5AmountFormatter.measuredFont(size: 34)
        for themeID in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
            let preset = PanelOdometerPreset.resolve(themeID: themeID)
            for pair: (Int64, Int64) in [(12_009, 12_010), (12_099, 12_100), (99_999, 100_000), (999_999, 1_000_000)] {
                let native = PanelAmountNativeView(frame: CGRect(x: 0, y: 0, width: 280, height: 35))
                native.apply(amount: .live(try .init(validating: pair.0)), font: font, color: .black,
                             preset: preset, motionEnabled: true, calibration: 0, height: 35)
                native.apply(amount: .live(try .init(validating: pair.1)), font: font, color: .black,
                             preset: preset, motionEnabled: true, calibration: 0, height: 35)
                XCTAssertEqual(native.targetText, Stage5AmountFormatter.string(minorUnits: pair.1, fractionDigits: 3))
                XCTAssertEqual(native.lastDirection, 1)
                XCTAssertEqual(native.lastDuration, themeID == BuiltinThemeID.warmIsland ? 0.160 : 0.180)
                XCTAssertLessThanOrEqual(native.lastDuration, 0.220)
                XCTAssertEqual(preset.staggerMilliseconds, 0)
                XCTAssertEqual(native.renderedGlyphs.first { $0.key == "fraction-0" }?.frame.minX, 166)
                let incoming = try XCTUnwrap(native.incomingAnimation(for: "fraction-3"))
                XCTAssertEqual(incoming.duration, preset.duration)
                let from = try XCTUnwrap(incoming.fromValue as? NSNumber).doubleValue
                let to = try XCTUnwrap(incoming.toValue as? NSNumber).doubleValue
                XCTAssertEqual(to - from, Double(font.pointSize * preset.displacementEm), accuracy: 0.001)
                var control = [Float](repeating: 0, count: 2)
                control.withUnsafeMutableBufferPointer {
                    incoming.timingFunction?.getControlPoint(at: 1, values: $0.baseAddress!)
                }
                XCTAssertEqual(control, [0.22, 1])
                control.withUnsafeMutableBufferPointer {
                    incoming.timingFunction?.getControlPoint(at: 2, values: $0.baseAddress!)
                }
                XCTAssertEqual(control, [0.36, 1])
                native.apply(amount: .live(try .init(validating: pair.0)), font: font, color: .black,
                             preset: preset, motionEnabled: true, calibration: 0, height: 35)
                XCTAssertEqual(native.lastDirection, -1)
                let downward = try XCTUnwrap(native.incomingAnimation(for: "fraction-3"))
                XCTAssertGreaterThan(try XCTUnwrap(downward.fromValue as? NSNumber).doubleValue,
                                     try XCTUnwrap(downward.toValue as? NSNumber).doubleValue)
            }
        }
    }

    func testNativeOdometerCancelsForReduceMotionCalibrationAndSettlement() throws {
        let native = PanelAmountNativeView(frame: CGRect(x: 0, y: 0, width: 280, height: 35))
        let font = Stage5AmountFormatter.measuredFont(size: 34)
        let preset = PanelOdometerPreset.resolve(themeID: BuiltinThemeID.warmIsland)
        func apply(_ value: Int64, motion: Bool = true, calibration: Int = 0) throws {
            native.apply(amount: .live(try .init(validating: value)), font: font, color: .black,
                         preset: preset, motionEnabled: motion, calibration: calibration, height: 35)
        }
        try apply(12_009)
        XCTAssertEqual(native.activeAnimationCount, 0)
        try apply(12_009)
        XCTAssertEqual(native.activeAnimationCount, 0, "No change may manufacture rolling digits")
        try apply(12_010)
        XCTAssertGreaterThan(native.activeAnimationCount, 0)
        try apply(12_010, motion: false)
        XCTAssertEqual(native.activeAnimationCount, 0)
        try apply(12_011, motion: false)
        XCTAssertEqual(native.targetText, "¥12.011")
        XCTAssertEqual(native.activeAnimationCount, 0)
        try apply(18_999, calibration: 1)
        XCTAssertEqual(native.targetText, "¥18.999")
        XCTAssertEqual(native.activeAnimationCount, 0, "Resume must replace the target without replay")
        try apply(19_000, calibration: 1)
        XCTAssertGreaterThan(native.activeAnimationCount, 0)
        native.apply(amount: .rounded(try .init(validating: 1_900)), font: font, color: .black,
                     preset: preset, motionEnabled: true, calibration: 1, height: 35)
        XCTAssertEqual(native.targetText, "¥19.00")
        XCTAssertEqual(native.activeAnimationCount, 0)
    }

    func testProductionPanelDirectOnePixelPerPointRendersAmountExtremesAndTextScales() async throws {
        let profile = PanelPresentationProfileRegistry().standard
        let settings = ApplicationTestSupport.committedSettings(wageCents: 99_999_999)
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: start)
        let themes = ThemeStore()
        await themes.restore()
        await themes.setAppearance(.light)
        var rows: [[String: Any]] = []
        func amountView(in view: NSView) -> PanelAmountNativeView? {
            if let amount = view as? PanelAmountNativeView { return amount }
            return view.subviews.lazy.compactMap { amountView(in: $0) }.first
        }
        for settled in [false, true] {
            let now = settled ? ApplicationTestSupport.timestamp(hour: 18) : start
            let store = try BusinessStore(repository: BusinessRecordRepositorySpy(
                settings: .loaded(settings, migration: .current), today: .loaded(today, migration: .current)),
                nowProvider: MutableTestClock(now), timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await store.restore()
            if settled {
                let result = await store.send(.requestClockOut, source: .panel)
                XCTAssertEqual(result, .committed)
            }
            XCTAssertEqual(store.viewState?.state, settled ? .completed : .earning)
            let expectedText = settled ? "¥999,999.99" : "¥0.000"
            XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), expectedText)
            for themeID in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
                await themes.selectTheme(id: themeID)
                XCTAssertEqual(themes.selectedTheme.id, themeID)
                for textScale: CGFloat in [1, 1.2] {
                    let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themes,
                        profile: profile, onOpenSettings: {}, onHide: {},
                        renderPulse: PanelRenderPulseCoordinator(isVisible: false))
                        .environment(\.incomePanelTextScale, textScale))
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: profile.contentSize),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderFrontRegardless()
                    defer { window.orderOut(nil); window.close() }
                    for _ in 0..<100 {
                        host.layoutSubtreeIfNeeded()
                        if amountView(in: host)?.targetText == expectedText { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.fittingSize, profile.contentSize)
                    let amount = try XCTUnwrap(amountView(in: host))
                    XCTAssertEqual(amount.targetText, expectedText)
                    XCTAssertEqual(amount.activeAnimationCount, 0)
                    XCTAssertFalse(amount.renderedGlyphs.isEmpty)
                    let glyphHeight: CGFloat = settled ? 48 - 13 * textScale : 60 - 25 * textScale
                    let design: Font.Design = themes.selectedTheme.manifest.amountFontDesign == .rounded ? .rounded : .default
                    let weight: Font.Weight = themes.selectedTheme.manifest.amountFontWeight == "semibold" ? .semibold : .medium
                    let expectedFont = Stage5AmountFormatter.fontSize(for: expectedText, weight: weight,
                        design: design, textScale: textScale, availableHeight: glyphHeight)
                    XCTAssertEqual(amount.appliedFontSize, expectedFont)
                    for glyph in amount.renderedGlyphs {
                        XCTAssertEqual(glyph.frame.height, glyphHeight, accuracy: 0.001)
                        XCTAssertGreaterThanOrEqual(glyph.frame.minX, 4)
                        XCTAssertLessThanOrEqual(glyph.frame.maxX, 276)
                        XCTAssertGreaterThanOrEqual(glyph.frame.minY, 0)
                        XCTAssertLessThanOrEqual(glyph.frame.maxY, amount.bounds.height)
                    }
                    // Inspect the recommended bitmap's pixel FORMAT only. Never
                    // draw a 2x snapshot or resize an existing image to make 1x.
                    let format = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: Int(profile.contentSize.width), pixelsHigh: Int(profile.contentSize.height),
                        bitsPerSample: format.bitsPerSample, samplesPerPixel: format.samplesPerPixel,
                        hasAlpha: format.hasAlpha, isPlanar: format.isPlanar,
                        colorSpaceName: format.colorSpaceName, bitmapFormat: format.bitmapFormat,
                        bytesPerRow: 0, bitsPerPixel: 0))
                    bitmap.size = profile.contentSize
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    XCTAssertEqual(bitmap.pixelsWide, 320)
                    XCTAssertEqual(bitmap.pixelsHigh, 190)
                    XCTAssertEqual(bitmap.size, profile.contentSize)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
                    XCTAssertEqual(decoded.pixelsWide, 320)
                    XCTAssertEqual(decoded.pixelsHigh, 190)
                    let name = "Stage9-Direct1x-\(settled ? "maximum-settled" : "minimum-live")-\(themeID)-text\(Int(textScale * 100))-light"
                    // Raw PNG attachment preserves this exact pixel raster;
                    // XCTAttachment(image:) may choose the screen's 2x density.
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    rows.append(["attachment": name, "theme": themeID, "appearance": "light",
                        "state": settled ? "COMPLETED" : "EARNING", "amount": expectedText,
                        "textScale": Double(textScale), "pixelsWide": bitmap.pixelsWide,
                        "pixelsHigh": bitmap.pixelsHigh, "logicalWidth": 320, "logicalHeight": 190,
                        "rasterPixelsPerPoint": 1, "mountedWindowBackingScale": Double(window.backingScaleFactor),
                        "producer": "NSHostingView.cacheDisplay directly into allocated 320x190 bitmap; no image resize",
                        "scope": "Offscreen bitmap raster evidence; not physical 1x display hardware acceptance"])
                }
            }
        }
        XCTAssertEqual(rows.count, 8)
        let manifest = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        manifest.name = "Stage9-Direct1x-Manifest"
        manifest.lifetime = .keepAlways
        add(manifest)
    }

    func testProductionPanelAt120PercentRendersAllStatesThemesAndAppearances() async throws {
        let settings = ApplicationTestSupport.committedSettings(wageCents: 99_999_999)
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let today = try calendar.proposedToday(from: settings, at: start)
        let themeStore = ThemeStore()
        await themeStore.restore()
        let profile = PanelPresentationProfileRegistry().standard
        for state in [WorkdayState.unconfigured, .ready, .clockedInWaiting, .earning, .awaitingClockOut, .completed, .recoveryRequired] {
            let clock = MutableTestClock(state == .clockedInWaiting ? ApplicationTestSupport.timestamp(hour: 8) :
                state == .earning ? .init(rawValue: ApplicationTestSupport.timestamp(hour: 18).rawValue - 1) :
                state == .awaitingClockOut || state == .completed ? ApplicationTestSupport.timestamp(hour: 18) : start)
            let repository: BusinessRecordRepositorySpy
            if state == .unconfigured {
                repository = BusinessRecordRepositorySpy(settings: .missing, today: .missing)
            } else if state == .ready {
                repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current), today: .missing)
            } else if state == .recoveryRequired {
                repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
                    today: .damaged(.init(kind: .today, issue: .invalidSchemaEnvelope, disposition: .requireTodayReset)))
            } else {
                let record = state == .clockedInWaiting
                    ? try calendar.proposedToday(from: settings, at: ApplicationTestSupport.timestamp(hour: 8)) : today
                repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
                    today: .loaded(record, migration: .current))
            }
            let store = try BusinessStore(repository: repository, nowProvider: clock,
                                          timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await store.restore()
            if state == .completed { _ = await store.send(.requestClockOut, source: .panel) }
            XCTAssertEqual(store.viewState?.state, state)
            for themeID in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
                await themeStore.selectTheme(id: themeID)
                XCTAssertEqual(themeStore.selectedTheme.id, themeID)
                for appearance in [PreferredThemeAppearance.light, .dark] {
                    await themeStore.setAppearance(appearance)
                    let pulse = PanelRenderPulseCoordinator(isVisible: false)
                    let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themeStore,
                        profile: profile, onOpenSettings: {}, onHide: {}, renderPulse: pulse)
                        .environment(\.incomePanelTextScale, 1.2))
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: profile.contentSize),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderFrontRegardless()
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 30_000_000)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.fittingSize, profile.contentSize)
                    func amountView(in parent: NSView) -> PanelAmountNativeView? {
                        if let amount = parent as? PanelAmountNativeView { return amount }
                        return parent.subviews.lazy.compactMap { amountView(in: $0) }.first
                    }
                    if state != .recoveryRequired {
                        let amount = try XCTUnwrap(amountView(in: host))
                        XCTAssertEqual(amount.targetText, Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount))
                        XCTAssertEqual(host.convert(CGPoint(x: 166, y: 0), from: amount).x, 178, accuracy: 0.01)
                        XCTAssertGreaterThanOrEqual(amount.appliedFontSize, 26)
                        let amountDesign: Font.Design = themeStore.selectedTheme.manifest.amountFontDesign == .rounded ? .rounded : .default
                        let amountWeight: Font.Weight = themeStore.selectedTheme.manifest.amountFontWeight == "semibold" ? .semibold : .medium
                        // UI Contract §6.2 gives current-day settlement a 48pt amount block;
                        // §3.2 gives other states 60pt, including label and precision rows.
                        // This matrix has no previous-workday settlement (whose block is 42pt).
                        let expectedHeight: CGFloat = state == .completed ? 48 - 13 * 1.2 : 60 - 25 * 1.2
                        let context = "state=\(state), theme=\(themeID), appearance=\(appearance), textScale=1.2, height=\(amount.bounds.height), expectedHeight=\(expectedHeight)"
                        XCTAssertFalse(amount.renderedGlyphs.isEmpty, context)
                        for glyph in amount.renderedGlyphs {
                            XCTAssertEqual(glyph.frame.height, expectedHeight, accuracy: 0.001, context)
                            XCTAssertGreaterThanOrEqual(glyph.frame.minY, 0, context)
                            XCTAssertLessThanOrEqual(glyph.frame.maxY, amount.bounds.height, context)
                        }
                        let expectedSize = Stage5AmountFormatter.fontSize(for: amount.targetText,
                            weight: amountWeight, design: amountDesign, textScale: 1.2,
                            availableHeight: expectedHeight)
                        XCTAssertEqual(amount.appliedFontSize, expectedSize, context)
                        let inkFont = Stage5AmountFormatter.measuredFont(size: amount.appliedFontSize, weight: amountWeight, design: amountDesign)
                        let ink = Stage5AmountFormatter.numericInkBounds(font: inkFont)
                        let baseline = Stage5AmountFormatter.amountBaseline(font: inkFont, height: expectedHeight)
                        XCTAssertGreaterThanOrEqual(ink.minY + baseline, 1 - 0.001, context)
                        XCTAssertLessThanOrEqual(ink.maxY + baseline, expectedHeight - 1 + 0.001, context)
                        XCTAssertTrue(amount.renderedGlyphs.allSatisfy { $0.frame.minX >= 4 && $0.frame.maxX <= 276 })
                        XCTAssertEqual(amount.activeAnimationCount, 0)
                    } else {
                        XCTAssertNil(amountView(in: host), "Recovery must expose no unverified amount")
                    }
                    let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: image)
                    let name = "Stage9-Text120-\(state)-\(themeID)-\(appearance)"
                    addRenderAttachment(image, logicalSize: profile.contentSize, name: name)
                    if let directory = ProcessInfo.processInfo.environment["INCOMECLOCK_STAGE9_PRESENTATION_RENDER_ROOT"] {
                        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
                    }
                    window.orderOut(nil)
                    window.close()
                }
            }
        }
    }

    func testProductionTimelineDrivesHostedPanelAndStopsSamplingWhenHidden() async throws {
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let settings = ApplicationTestSupport.committedSettings(wageCents: 99_999_999)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: start)
        let clock = MutableTestClock(start)
        let store = try BusinessStore(repository: BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current), today: .loaded(today, migration: .current)),
            nowProvider: clock, timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        let pulse = PanelRenderPulseCoordinator()
        let profile = PanelPresentationProfileRegistry().standard
        let host = NSHostingView(rootView: IncomePanelView(businessStore: store,
            profile: profile, onOpenSettings: {}, onHide: {}, renderPulse: pulse))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: profile.contentSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { pulse.setVisible(false); window.orderOut(nil); window.close() }
        // No direct pulse/refresh invocation: only the mounted production timeline
        // can consume the changed authoritative clock in this part of the test.
        clock.resetSampleCount()
        clock.set(.init(rawValue: start.rawValue + 1_000))
        try await waitUntil { Stage5AmountFormatter.string(for: store.viewState!.amount) == "¥30.864" }
        XCTAssertGreaterThan(clock.sampleCount, 0)
        pulse.setVisible(false)
        window.orderOut(nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        clock.resetSampleCount()
        clock.set(.init(rawValue: start.rawValue + 2_000))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(clock.sampleCount, 0)
        XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥30.864")
        window.orderFrontRegardless()
        pulse.setVisible(true)
        try await waitUntil { Stage5AmountFormatter.string(for: store.viewState!.amount) == "¥61.728" }
        clock.set(.init(rawValue: ApplicationTestSupport.timestamp(hour: 18).rawValue - 1))
        try await waitUntil { Stage5AmountFormatter.string(for: store.viewState!.amount) == "¥999,999.959" }
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        XCTAssertEqual(host.fittingSize, profile.contentSize)
        addRenderAttachment(representation, logicalSize: profile.contentSize, name: "Stage9-Maximum-Live-Amount-Production-Panel")
        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        try await waitUntil { store.viewState?.state == .awaitingClockOut }
        XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥999,999.99")
    }

    func testNativePulseTargetsAgreeAtThirtySixtyAndSkippedFrameSchedules() async throws {
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let schedules = [Array(stride(from: 0, through: 1_000, by: 33)),
                         Array(stride(from: 0, through: 1_000, by: 16)),
                         [0, 8, 731]]
        var outputs: [String] = []
        for samples in schedules {
            let settings = ApplicationTestSupport.committedSettings()
            let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
                .proposedToday(from: settings, at: start)
            let clock = MutableTestClock(start)
            let store = try BusinessStore(repository: BusinessRecordRepositorySpy(
                settings: .loaded(settings, migration: .current), today: .loaded(today, migration: .current)),
                nowProvider: clock, timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await store.restore()
            let pulse = PanelRenderPulseCoordinator()
            for offset in samples + [1_000] {
                clock.set(.init(rawValue: start.rawValue + Int64(offset)))
                await pulse.pulse(store)
            }
            outputs.append(try XCTUnwrap(Stage5AmountFormatter.string(for: XCTUnwrap(store.viewState).amount)))
        }
        XCTAssertEqual(outputs, ["¥0.009", "¥0.009", "¥0.009"])
    }

    func testNativePulseChangesOnlyAtRealMilliYuanBoundaryAndResumesAtCurrentTarget() async throws {
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let settings = ApplicationTestSupport.committedSettings()
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: start)
        let clock = MutableTestClock(start)
        let store = try BusinessStore(repository: BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current), today: .loaded(today, migration: .current)),
            nowProvider: clock, timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        let pulse = PanelRenderPulseCoordinator()
        for offset in [0, 1, 20, 53] {
            clock.set(.init(rawValue: start.rawValue + Int64(offset)))
            await pulse.pulse(store)
            XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥0.000")
        }
        clock.set(.init(rawValue: start.rawValue + 54))
        await pulse.pulse(store)
        XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥0.001")
        pulse.setVisible(false)
        clock.set(.init(rawValue: start.rawValue + 600_000))
        await pulse.pulse(store)
        XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥0.001")
        pulse.setVisible(true)
        await pulse.pulse(store)
        XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥5.556")
        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        await pulse.pulse(store)
        XCTAssertEqual(store.viewState?.state, .awaitingClockOut)
        XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥300.00")
    }

    func testAmountSelectorReselectsDiscreteTierForTextScaleAndFitsRealGlyphInk() throws {
        XCTAssertEqual(Stage5AmountFormatter.amountHeight(textScale: 1), 35)
        XCTAssertEqual(Stage5AmountFormatter.amountHeight(textScale: 1.2), 30)
        let tiers = [CGFloat(34), 32, 30, 28, 26]
        for scale: CGFloat in [1, 1.1, 1.2] {
            for design: Font.Design in [.default, .rounded] {
                for weight: Font.Weight in [.medium, .semibold, .bold] {
                    for text in ["¥999.999", "¥1,000.000", "¥99,999.999", "¥100,000.000", "¥999,999.990"] {
                        let height = Stage5AmountFormatter.amountHeight(textScale: scale)
                        let selected = Stage5AmountFormatter.fontSize(for: text, weight: weight, design: design, textScale: scale)
                        let independentlyFitting = tiers.filter { candidate in
                            let font = Stage5AmountFormatter.measuredFont(size: candidate, weight: weight, design: design)
                            let glyphs = PanelAmountGeometry.glyphs(text, font: font, height: height)
                            let ink = Stage5AmountFormatter.numericInkBounds(font: font)
                            return glyphs.allSatisfy { $0.frame.minX >= 4 && $0.frame.maxX <= 276 }
                                && ink.height <= height - 2
                        }
                        XCTAssertEqual(selected, try XCTUnwrap(independentlyFitting.first))
                        let font = Stage5AmountFormatter.measuredFont(size: selected, weight: weight, design: design)
                        let ink = Stage5AmountFormatter.numericInkBounds(font: font)
                        let baseline = Stage5AmountFormatter.amountBaseline(font: font, height: height)
                        XCTAssertGreaterThanOrEqual(ink.minY + baseline, 1 - 0.001)
                        XCTAssertLessThanOrEqual(ink.maxY + baseline, height - 1 + 0.001)
                        XCTAssertEqual(PanelAmountGeometry.panelAnchor, 178)
                        XCTAssertTrue(tiers.contains(selected), "Text scale must never manufacture a fractional font tier")
                    }
                }
            }
        }
    }

    func testNativeAmountFontsGiveAllTenDigitsEqualAdvanceForBothBuiltinThemes() async throws {
        let catalog = await BundledThemeCatalog().loadBuiltInThemes()
        XCTAssertEqual(Set(catalog.themes.map(\.id)), [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion])
        for theme in catalog.themes {
            let design: Font.Design = theme.manifest.amountFontDesign == .rounded ? .rounded : .default
            let token = theme.manifest.amountFontWeight.lowercased()
            let weight: Font.Weight = token == "bold" ? .bold : token == "semibold" ? .semibold : .medium
            for size: CGFloat in [34, 32, 30, 28, 26] {
                let font = Stage5AmountFormatter.measuredFont(size: size, weight: weight, design: design)
                let advances = (0...9).map { digit in
                    (String(digit) as NSString).size(withAttributes: [.font: font]).width
                }
                let expected = try XCTUnwrap(advances.first)
                XCTAssertTrue(expected.isFinite)
                XCTAssertGreaterThan(expected, 0)
                for (digit, advance) in advances.enumerated() {
                    // 1e-6pt covers floating-point representation only. It is not
                    // a pixel/layout tolerance and cannot admit proportional digits.
                    XCTAssertEqual(advance, expected, accuracy: 0.000_001,
                        "\(theme.id) \(font.fontName) \(size)pt digit=\(digit) advances=\(advances)")
                }
                print("TABULAR FONT theme=\(theme.id) font=\(font.fontName) size=\(size) advances=\(advances)")
            }
        }
    }

    func testAmountUsesMeasuredDiscreteFontAtBothCarryBoundariesAndMaximumWage() {
        for design: Font.Design in [.default, .rounded] {
            for weight: Font.Weight in [.medium, .semibold, .bold] {
                for amount in ["¥999.999", "¥1,000.000", "¥99,999.999", "¥100,000.000", "¥999,999.990"] {
                    let size = Stage5AmountFormatter.fontSize(for: amount, weight: weight, design: design)
                    XCTAssertTrue([CGFloat(34), 32, 30, 28, 26].contains(size))
                    let font = Stage5AmountFormatter.measuredFont(size: size, weight: weight, design: design)
                    let attributes: [NSAttributedString.Key: Any] = [.font: font]
                    let parts = amount.split(separator: ".")
                    XCTAssertLessThanOrEqual((String(parts[0]) as NSString).size(withAttributes: attributes).width, 162)
                    XCTAssertLessThanOrEqual((".\(parts[1])" as NSString).size(withAttributes: attributes).width, 110)
                    XCTAssertLessThanOrEqual((amount as NSString).size(withAttributes: attributes).width, 272)
                }
            }
        }
        XCTAssertEqual(Stage5AmountFormatter.fontSize(for: "¥999.999"), 34)
        XCTAssertEqual(Stage5AmountFormatter.fontSize(for: "¥1,000.000"), 34)
        XCTAssertEqual(Stage5AmountFormatter.fontSize(for: "¥100,000.000"),
                       Stage5AmountFormatter.fontSize(for: "¥999,999.990"))
    }

    func testDurationAndVoiceOverValuesPreserveLiveVersusSettledSemantics() throws {
        XCTAssertEqual(Stage5DurationFormatter.string(try .init(validating: 13_638_000)), "03:47:18")
        let live = BusinessEarnedAmount.live(try .init(validating: 123_456))
        let settled = BusinessEarnedAmount.rounded(try .init(validating: 12_346))
        XCTAssertTrue(Stage5AmountFormatter.accessibilityValue(for: live).contains("实时收入估算"))
        XCTAssertTrue(Stage5AmountFormatter.accessibilityValue(for: settled).contains("已结算"))
    }

    func testWorkRuleParserUsesOnlyExplicitFieldsAndRejectsMalformedDrafts() throws {
        let parsed = try WorkRuleDraftParser.parse(wage: "300.50", start: "09:00", end: "18:30")
        XCTAssertEqual(parsed.dailyWageCents, 30_050)
        XCTAssertEqual(parsed.workStartMinuteOfDay, 540)
        XCTAssertEqual(parsed.workEndMinuteOfDay, 1_110)
        XCTAssertThrowsError(try WorkRuleDraftParser.parse(wage: "300.001", start: "09:00", end: "18:00"))
        XCTAssertThrowsError(try WorkRuleDraftParser.parse(wage: "300", start: "9:00", end: "18:00"))
        XCTAssertThrowsError(try WorkRuleDraftParser.parse(wage: "300", start: "18:00", end: "09:00"))
    }

    func testWarmIslandPanelRendersAtStandardProfileSize() async throws {
        let repository = BusinessRecordRepositorySpy(settings: .missing, today: .missing)
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        await store.restore()
        let profile = PanelPresentationProfileRegistry().standard
        let host = NSHostingView(rootView: IncomePanelView(
            businessStore: store, profile: profile, onOpenSettings: {}, onHide: {}
        ))
        host.frame = CGRect(origin: .zero, size: profile.contentSize)
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)

        XCTAssertEqual(host.fittingSize, profile.contentSize)
        XCTAssertTrue([320, 640].contains(representation.pixelsWide))
        XCTAssertEqual(representation.pixelsHigh * 32, representation.pixelsWide * 19)
        addRenderAttachment(representation, logicalSize: profile.contentSize, name: "Stage5-WarmIsland-Panel")
        try writeRenderIfRequested(representation, environmentKey: "INCOMECLOCK_STAGE5_PANEL_RENDER")
    }

    func testCompletedPanelRendersContractCopyAtStandardProfileSize() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let calendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let proposed = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(hour: 10)
        )
        let clockOut = ApplicationTestSupport.timestamp(hour: 11)
        let completed = TodayRecord(
            schemaVersion: proposed.schemaVersion,
            revision: .init(rawValue: 1),
            dateKey: proposed.dateKey,
            clockInAtMs: proposed.clockInAtMs,
            clockOutAtMs: clockOut.rawValue,
            settingsSnapshot: proposed.settingsSnapshot,
            scheduledStartAtMs: proposed.scheduledStartAtMs,
            scheduledEndAtMs: proposed.scheduledEndAtMs,
            notificationScheduledDateKey: proposed.notificationScheduledDateKey,
            notificationRequestIdentifier: proposed.notificationRequestIdentifier,
            updatedAtMs: clockOut.rawValue
        )
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(completed, migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        await store.restore()
        let state = try XCTUnwrap(store.viewState)
        XCTAssertEqual(state.state, .completed)
        let presentation = Stage5PanelPresentation.make(from: state)
        XCTAssertEqual(presentation.supportText, "计薪时长 01:00:00")
        XCTAssertEqual(presentation.durationText, "上班 10:00:00 · 下班 11:00:00")
        XCTAssertEqual(presentation.amount?.split(separator: ".").last?.count, 2)

        let profile = PanelPresentationProfileRegistry().standard
        let host = NSHostingView(rootView: IncomePanelView(
            businessStore: store, profile: profile, onOpenSettings: {}, onHide: {}
        ))
        host.frame = CGRect(origin: .zero, size: profile.contentSize)
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)

        XCTAssertEqual(host.fittingSize, profile.contentSize)
        XCTAssertTrue([320, 640].contains(representation.pixelsWide))
        XCTAssertEqual(representation.pixelsHigh * 32, representation.pixelsWide * 19)
        addRenderAttachment(
            representation,
            logicalSize: profile.contentSize,
            name: "Stage5-Completed-Panel"
        )
        try writeRenderIfRequested(
            representation,
            environmentKey: "INCOMECLOCK_STAGE5_COMPLETED_RENDER"
        )
    }

    func testSettingsWindowRendersAllNavigationAtMinimumSize() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current),
            today: .missing
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        await store.restore()
        XCTAssertEqual(Stage5SettingsSection.allCases.count, 7)
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy())
        let host = NSHostingView(rootView: IncomeSettingsView(environment: environment))
        host.frame = CGRect(x: 0, y: 0, width: 680, height: 500)
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)

        XCTAssertGreaterThanOrEqual(host.fittingSize.width, 680)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 500)
        addRenderAttachment(representation, logicalSize: CGSize(width: 680, height: 500), name: "Stage5-Settings-Window")
        try writeRenderIfRequested(representation, environmentKey: "INCOMECLOCK_STAGE5_SETTINGS_RENDER")
    }

    private func viewState(
        _ state: WorkdayState,
        previous: Bool = false,
        canStartToday: Bool = false
    ) throws -> BusinessViewState {
        let amount: BusinessEarnedAmount
        switch state {
        case .unconfigured, .ready: amount = .rounded(try .init(validating: 0))
        case .clockedInWaiting: amount = .live(try .init(validating: 0))
        case .earning: amount = .live(try .init(validating: 123_456))
        case .awaitingClockOut, .completed: amount = .rounded(try .init(validating: 12_346))
        case .recoveryRequired: amount = .hidden
        }
        return .init(state: state,
            recoveryReason: state == .recoveryRequired ? .unreadableTodayRecord : nil,
            amount: amount,
            earnedDuration: try .init(validating: 13_638_000),
            scheduledProgress: state == .awaitingClockOut ? 1 : 0.5,
            remainingToStart: try .init(validating: 3_600_000),
            remainingToEnd: try .init(validating: 7_200_000),
            clockInAt: .init(rawValue: 1_755_396_600_000),
            clockOutAt: .init(rawValue: 1_755_410_238_000),
            todayDateKey: "2026-08-17", todayTimeZoneIdentifier: "Asia/Shanghai",
            isPreviousWorkday: previous, clockOutDateKey: "2026-08-17",
            canClockIn: state == .ready, canRequestClockOut: [.clockedInWaiting, .earning, .awaitingClockOut].contains(state),
            canRequestTodayReset: state == .recoveryRequired, canRequestStartToday: canStartToday,
            canRequestSettingsReset: false, previousDayCleanupPending: false)
    }

    private func writeRenderIfRequested(_ representation: NSBitmapImageRep,
                                        environmentKey: String) throws {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else { return }
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for semantic keyboard action")
    }

    private func addRenderAttachment(_ representation: NSBitmapImageRep,
                                     logicalSize: CGSize,
                                     name: String) {
        let image = NSImage(size: logicalSize)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private actor FilePanelPreferenceStore: PanelPreferenceStoring {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> PendingPanelPreferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingPanelPreferences.self, from: data)
    }

    func save(_ preferences: PendingPanelPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor HoldingPanelPreferenceStore: PanelPreferenceStoring {
    private var preferences: PendingPanelPreferences?
    private var shouldHoldNextLoad = false
    private var isHoldingLoad = false
    private var heldLoadContinuation: CheckedContinuation<Void, Never>?

    func holdNextLoad() {
        shouldHoldNextLoad = true
    }

    func waitUntilLoadIsHeld() async {
        while !isHoldingLoad {
            await Task.yield()
        }
    }

    func resumeHeldLoad() {
        heldLoadContinuation?.resume()
        heldLoadContinuation = nil
    }

    func load() async -> PendingPanelPreferences? {
        if shouldHoldNextLoad {
            shouldHoldNextLoad = false
            isHoldingLoad = true
            await withCheckedContinuation { continuation in
                heldLoadContinuation = continuation
            }
            isHoldingLoad = false
        }
        return preferences
    }

    func save(_ preferences: PendingPanelPreferences) {
        self.preferences = preferences.isEmpty ? nil : preferences
    }

    func clear() {
        preferences = nil
    }
}

final class MutablePanelScreenProvider: PanelScreenProviding {
    var screens: [PanelScreenDescriptor]

    var mainScreen: PanelScreenDescriptor? {
        screens.first(where: \.isMain) ?? screens.first
    }

    init(screens: [PanelScreenDescriptor]) {
        self.screens = screens
    }
}

private extension NSWindow {
    var isResizable: Bool {
        styleMask.contains(.resizable)
    }
}

@MainActor
final class ThemeSoundRuntimeTests: XCTestCase {
    func testDefaultOffThenOnlyDiscreteSuccessAutoStopAndSettlementEventsPlayOnce() async throws {
        let fixture = try SoundRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 9))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current))
        let store = try BusinessStore(repository: repository, nowProvider: clock,
                                      timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let themes = fixture.themeStore()
        let player = SoundRuntimePlayerSpy()
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(),
                                         themeStore: themes, themeSoundPlayer: player)
        await environment.start()
        XCTAssertFalse(themes.soundsEnabled)
        let clockIn = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(clockIn, .committed)
        XCTAssertTrue(player.played.isEmpty)
        await themes.setSoundsEnabled(true)
        await store.refresh()
        XCTAssertTrue(player.played.isEmpty, "Enabling must not replay the previous clock-in")
        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        await store.refresh()
        XCTAssertEqual(player.played, [Data("autoStop".utf8)])
        await store.refresh()
        XCTAssertEqual(player.played.count, 1)
        let clockOut = await store.send(.requestClockOut, source: .menuBar)
        XCTAssertEqual(clockOut, .committed)
        XCTAssertEqual(player.played, [Data("autoStop".utf8), Data("settlementComplete".utf8)])
        await store.refresh()
        await environment.restoreBusinessState()
        XCTAssertEqual(player.played.count, 2)
        XCTAssertTrue(environment.themeSoundCoordinator.diagnostics.isEmpty)
    }

    func testClockInPlaybackFailureIsDiagnosticOnlyAndPreservesCommittedBusinessResult() async throws {
        let fixture = try SoundRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        let settings = ApplicationTestSupport.committedSettings()
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 9))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current))
        let controlRepository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current))
        let store = try BusinessStore(repository: repository, nowProvider: clock,
                                      timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let control = try BusinessStore(repository: controlRepository, nowProvider: clock,
                                        timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let player = SoundRuntimePlayerSpy()
        player.shouldThrow = true
        let themes = fixture.themeStore()
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(),
                                         themeStore: themes, themeSoundPlayer: player)
        await environment.start()
        await control.restore()
        await themes.setSoundsEnabled(true)
        let outcome = await store.send(.clockIn, source: .panel)
        let controlOutcome = await control.send(.clockIn, source: .panel)
        XCTAssertEqual(outcome, controlOutcome)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(store.viewState, control.viewState)
        XCTAssertEqual(store.feedback, control.feedback)
        let saved = await repository.currentToday()
        let controlSaved = await controlRepository.currentToday()
        XCTAssertEqual(saved, controlSaved)
        XCTAssertEqual(player.played, [Data("clockInSuccess".utf8)])
        XCTAssertEqual(environment.themeSoundCoordinator.diagnostics,
                       [.init(event: .clockInSuccess, failure: .playbackFailed)])
    }

    func testFIFOReplacementIsRejectedWithoutBlockingOrPlayingOrChangingBusiness() async throws {
        let fixture = try SoundRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        let settings = ApplicationTestSupport.committedSettings()
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 9))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current))
        let controlRepository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current))
        let store = try BusinessStore(repository: repository, nowProvider: clock,
                                     timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let control = try BusinessStore(repository: controlRepository, nowProvider: clock,
                                       timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let themes = fixture.themeStore()
        let player = SoundRuntimePlayerSpy()
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(),
                                         themeStore: themes, themeSoundPlayer: player)
        await environment.start()
        await control.restore()
        await themes.setSoundsEnabled(true)
        let controlOutcome = await control.send(.clockIn, source: .panel)

        // Replace only this fixture's declared sound after Theme restoration.
        let fifo = fixture.root.appendingPathComponent("Sounds/clockInSuccess.wav")
        try FileManager.default.removeItem(at: fifo)
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let stopRescue = DispatchSemaphore(value: 0)
        let rescueFinished = DispatchSemaphore(value: 0)
        let fifoPath = fifo.path
        // Make the regression bounded even if O_NONBLOCK is removed: a delayed
        // owned FIFO endpoint releases a blocked reader, without supplying bytes.
        // O_RDWR keeps that endpoint available until the production call returns.
        DispatchQueue.global(qos: .userInitiated).async {
            defer { rescueFinished.signal() }
            guard stopRescue.wait(timeout: .now() + 2) == .timedOut else { return }
            let endpoint = open(fifoPath, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            defer { if endpoint >= 0 { close(endpoint) } }
            stopRescue.wait()
        }
        defer {
            stopRescue.signal()
            XCTAssertEqual(rescueFinished.wait(timeout: .now() + 2), .success,
                           "Fixture rescue must finish before its owned directory is removed")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let outcome = await store.send(.clockIn, source: .panel)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 1.5, "FIFO rejection must complete before the two-second rescue endpoint")
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(outcome, controlOutcome)
        XCTAssertEqual(store.viewState, control.viewState)
        XCTAssertEqual(store.feedback, control.feedback)
        let saved = await repository.currentToday()
        let controlSaved = await controlRepository.currentToday()
        let savedSettings = await repository.currentSettings()
        let controlSettings = await controlRepository.currentSettings()
        XCTAssertEqual(saved, controlSaved)
        XCTAssertEqual(savedSettings, controlSettings)
        XCTAssertTrue(player.played.isEmpty)
        XCTAssertEqual(environment.themeSoundCoordinator.diagnostics,
                       [.init(event: .clockInSuccess, failure: .unsafeResource)])
        var metadata = stat()
        XCTAssertEqual(lstat(fifo.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, mode_t(S_IFIFO),
                       "Runtime rejection must not rewrite or delete the hostile resource")
    }

    func testSoundResolverRejectsTraversalLinksAndUnmappedFilesWithoutReadingOutsideTheme() throws {
        let fixture = try SoundRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        XCTAssertEqual(try ThemeSoundCoordinator.readVerifiedLocalSound(theme: fixture.theme, relativePath: "Sounds/clockInSuccess.wav"),
                       Data("clockInSuccess".utf8))
        for path in ["../outside.wav", "/tmp/outside.wav", "Sounds/unmapped.wav", "https://example.com/sound.wav"] {
            XCTAssertThrowsError(try ThemeSoundCoordinator.readVerifiedLocalSound(theme: fixture.theme, relativePath: path))
        }
        let linkedRoot = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: false)
        let outside = fixture.root.appendingPathComponent("owned-outside.wav")
        try Data("must not be loaded".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent("cue.wav"), withDestinationURL: outside)
        let linkedTheme = ValidatedTheme(manifest: fixture.theme.manifest, source: .installed(root: linkedRoot),
                                        sounds: ["clockInSuccess": "cue.wav"])
        XCTAssertThrowsError(try ThemeSoundCoordinator.readVerifiedLocalSound(theme: linkedTheme, relativePath: "cue.wav"))
    }
}

@MainActor
private final class SoundRuntimePlayerSpy: ThemeSoundPlaying {
    var played: [Data] = []
    var shouldThrow = false
    func play(_ data: Data, completion: @escaping @MainActor (Bool) -> Void) throws {
        played.append(data)
        if shouldThrow { throw ThemeSoundFailure.playbackFailed }
        completion(true)
    }
}

private struct SoundRuntimeCatalog: ThemeCatalogProviding {
    let theme: ValidatedTheme
    func loadBuiltInThemes() async -> ThemeCatalogSnapshot { .init(themes: [theme], diagnostics: []) }
}

@MainActor
private struct SoundRuntimeFixture {
    let root: URL
    let theme: ValidatedTheme
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IncomeClock-Sound-\(UUID().uuidString)", isDirectory: true)
        let sounds = root.appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        let names = ["clockInSuccess", "autoStop", "settlementComplete"]
        for name in names { try Data(name.utf8).write(to: sounds.appendingPathComponent(name + ".wav")) }
        theme = ValidatedTheme(manifest: ValidatedTheme.warmIslandFallback.manifest, source: .installed(root: root),
            sounds: Dictionary(uniqueKeysWithValues: names.map { ($0, "Sounds/\($0).wav") }))
    }
    func themeStore() -> ThemeStore {
        ThemeStore(repository: EphemeralThemePreferencesRepository(), catalog: SoundRuntimeCatalog(theme: theme))
    }
    func removeOwnedFiles() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
final class SettingsSuccessPresentationTests: XCTestCase {
    func testToastIsTwoSecondsAndAnOlderExpiryCannotDismissItsReplacement() async throws {
        let sleeper = SettingsToastControlledSleeper()
        var announcements: [String] = []
        let controller = SettingsSuccessToastController(announce: { announcements.append($0) },
            sleep: { try await sleeper.sleep($0) })
        controller.present("第一次成功", id: "first")
        try await waitFor { sleeper.count == 1 }
        controller.present("第二次成功", id: "second")
        try await waitFor { sleeper.count == 2 }
        XCTAssertEqual(sleeper.durations, [2_000_000_000, 2_000_000_000])
        sleeper.resume(0)
        await Task.yield()
        XCTAssertEqual(controller.text, "第二次成功")
        sleeper.resume(1)
        try await waitFor { controller.text == nil }
        controller.present("第二次成功", id: "second")
        XCTAssertNil(controller.text)
        XCTAssertEqual(announcements, ["第一次成功", "第二次成功"])
    }

    func testHostedSettingsAnnouncesCommittedReceiptOnceExpiresAndSuppressesFailure() async throws {
        let repository = BusinessRecordRepositorySpy()
        let store = try BusinessStore(repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        var announcements: [String] = []
        var observedErrors = 0
        let toast = SettingsSuccessToastController(announce: { announcements.append($0) })
        let host = NSHostingView(rootView: WorkRulesSettingsView(businessStore: store,
            messageObserver: { _, _, isError in if isError { observedErrors += 1 } }, successToast: toast))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 640, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        try await Task.sleep(nanoseconds: 80_000_000)
        let outcome = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(wageCents: 55_000)), source: .settings)
        XCTAssertEqual(outcome, .committed)
        try await waitFor { toast.text == "设置已保存" }
        XCTAssertEqual(announcements, ["设置已保存"])
        guard case let .settingsSaved(receipt)? = store.feedback else { return XCTFail("Missing committed receipt") }
        let committed = await repository.currentSettings()
        XCTAssertEqual(committed?.revision, receipt.committedRevision)
        XCTAssertEqual(committed?.dailyWageCents, 55_000)
        try await Task.sleep(nanoseconds: 1_550_000_000)
        XCTAssertEqual(toast.text, "设置已保存", "Toast must remain visible for at least 1.5 seconds")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(toast.text, "Toast must expire within 2.5 seconds")
        toast.present("设置已保存", id: receipt.context.commandID.uuidString)
        XCTAssertNil(toast.text, "The same committed receipt must not replay")
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        let failure = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(wageCents: 66_000)), source: .settings)
        XCTAssertNotEqual(failure, .committed)
        try await waitFor { observedErrors == 1 }
        XCTAssertNil(toast.text)
        XCTAssertEqual(announcements, ["设置已保存"])
        let unchanged = await repository.currentSettings()
        XCTAssertEqual(unchanged, committed)
    }

    func testHostedWorkRulesSavingAndFailureSurfacesPreserveAllSettingsTodayCombinations() async throws {
        for damaged in [false, true] {
            for todayKind in ["missing", "valid", "damaged"] {
                for conflict in [false, true] {
                    let initial = ApplicationTestSupport.committedSettings()
                    let today: RecordLoadResult<TodayRecord>
                    if todayKind == "missing" { today = .missing }
                    else if todayKind == "damaged" {
                        today = .damaged(.init(kind: .today, issue: .decodingFailed, disposition: .requireTodayReset))
                    } else {
                        let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
                        today = .loaded(try calendar.proposedToday(from: initial,
                            at: ApplicationTestSupport.timestamp(hour: 8)).replacingRevision(.init(rawValue: 1)), migration: .current)
                    }
                    let repository = BusinessRecordRepositorySpy(settings: damaged
                        ? .damaged(.init(kind: .settings, issue: .decodingFailed, disposition: .requireSettingsRecovery))
                        : .loaded(initial, migration: .current), today: today)
                    let store = try BusinessStore(repository: repository,
                        nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
                        timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
                    await store.restore()
                    let oldToday = try await repository.currentTodayCanonicalBytes()
                    var announcements: [String] = []
                    var errors: [String] = []
                    let toast = SettingsSuccessToastController(announce: { announcements.append($0) })
                    let host = NSHostingView(rootView: WorkRulesSettingsView(businessStore: store,
                        messageObserver: { _, text, error in if error { errors.append(text) } }, successToast: toast))
                    let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 640, height: 520),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderFront(nil)
                    host.layoutSubtreeIfNeeded()
                    try await Stage9EnableHostedAccessibility()
                    try await Task.sleep(nanoseconds: 80_000_000)
                    await repository.holdNextBusinessSettingsLoad()
                    await repository.holdNextSettingsSave()
                    await repository.failNextSettingsSave(with: conflict
                        ? .revisionConflict(expected: damaged ? nil : initial.revision, actual: .init(rawValue: 2))
                        : .atomicWriteFailed)
                    let command = Task { await store.send(.saveWorkRules(ApplicationTestSupport.workRules(wageCents: 66_000)), source: .settings) }
                    await repository.waitUntilBusinessSettingsLoadHeld()
                    do { try await waitFor { self.renderedAXText(host).contains("正在检查") } }
                    catch {
                        let dump = XCTAttachment(string: self.renderedAXText(host))
                        dump.name = "Hosted Settings AX at checking timeout"
                        dump.lifetime = .keepAlways
                        add(dump)
                        await repository.resumeBusinessSettingsLoad()
                        await repository.waitUntilSettingsSaveIsHeld()
                        await repository.resumeHeldSettingsSave()
                        _ = await command.value
                        window.close()
                        throw error
                    }
                    await repository.resumeBusinessSettingsLoad()
                    await repository.waitUntilSettingsSaveIsHeld()
                    do { try await waitFor { self.renderedAXText(host).contains("正在保存") } }
                    catch {
                        await repository.resumeHeldSettingsSave()
                        _ = await command.value
                        window.close()
                        throw error
                    }
                    XCTAssertTrue(store.isCommandInFlight)
                    XCTAssertNil(toast.text)
                    await repository.resumeHeldSettingsSave()
                    let outcome = await command.value
                    XCTAssertNotEqual(outcome, .committed)
                    try await waitFor { !errors.isEmpty }
                    try await waitFor { self.renderedAXText(host).contains(errors[0]) }
                    XCTAssertNil(toast.text)
                    XCTAssertTrue(announcements.isEmpty)
                    let retainedToday = try await repository.currentTodayCanonicalBytes()
                    XCTAssertEqual(retainedToday, oldToday)
                    XCTAssertFalse(store.isCommandInFlight)
                    window.close()
                }
            }
        }
    }

    private func renderedAXText(_ root: NSView) -> String {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any) -> [String] {
            let obj = object as AnyObject
            guard seen.insert(ObjectIdentifier(obj)).inserted else { return [] }
            let values: [String]
            let children: [Any]
            if let element = object as? NSObject {
                func attribute(_ name: String) -> Any? {
                    let selector = NSSelectorFromString(name)
                    guard element.responds(to: selector) else { return nil }
                    return element.perform(selector)?.takeUnretainedValue()
                }
                values = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].compactMap { attribute($0) as? String }
                children = attribute("accessibilityChildren") as? [Any] ?? []
            } else { return [] }
            return values + children.flatMap(visit)
        }
        return visit(root.window.map { $0 as NSObject } ?? root).joined(separator: "\n")
    }

    func testInstalledEmptyGroupPreservesBothBuiltinThemes() async throws {
        let catalog = await BundledThemeCatalog().loadBuiltInThemes()
        let groups = SettingsThemeGroups(themes: catalog.themes)
        XCTAssertEqual(Set(groups.builtIn.map(\.id)), [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion])
        XCTAssertTrue(groups.installed.isEmpty)
        XCTAssertTrue(groups.showsInstalledEmptyState)
        XCTAssertEqual(SettingsThemeGroups.installedEmptyTitle, "还没有导入皮肤")
        let installed = ValidatedTheme(manifest: ValidatedTheme.warmIslandFallback.manifest,
                                       source: .installed(root: URL(fileURLWithPath: "/unused-test-theme")))
        let populated = SettingsThemeGroups(themes: catalog.themes + [installed])
        XCTAssertEqual(populated.builtIn.count, 2)
        XCTAssertEqual(populated.installed, [installed])
        XCTAssertFalse(populated.showsInstalledEmptyState)
    }

    private func waitFor(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "SettingsPresentationTimeout", code: 1)
    }
}

@MainActor
private final class SettingsToastControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Error>?] = []
    private(set) var durations: [UInt64] = []
    var count: Int { durations.count }
    func sleep(_ duration: UInt64) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { continuation in continuations.append(continuation) }
    }
    func resume(_ index: Int) {
        continuations[index]?.resume()
        continuations[index] = nil
    }
}

@MainActor
final class SettingsWindowResizeBridgeTests: XCTestCase {
    func testBridgeChangesOnlyOwnedWindowStyleAndPreservesGeometry() async {
        let owner = NSWindow(contentRect: NSRect(x: 40, y: 50, width: 760, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 60, y: 70, width: 700, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { owner.close(); other.close() }
        owner.minSize = NSSize(width: 680, height: 532)
        owner.maxSize = NSSize(width: 1_200, height: 900)
        let frame = owner.frame
        let minSize = owner.minSize
        let maxSize = owner.maxSize
        let contentMinSize = owner.contentMinSize
        let contentMaxSize = owner.contentMaxSize
        let style = owner.styleMask
        let otherStyle = other.styleMask
        let bridge = SettingsWindowResizeView(frame: .zero)
        bridge.setAccessibilityElement(false)
        owner.contentView?.addSubview(bridge)
        await drainAttachmentCallbacks()
        XCTAssertEqual(owner.styleMask, style.union(.resizable))
        XCTAssertTrue(owner.isResizable)
        XCTAssertEqual(owner.frame, frame)
        XCTAssertEqual(owner.minSize, minSize)
        XCTAssertEqual(owner.maxSize, maxSize)
        XCTAssertEqual(owner.contentMinSize, contentMinSize)
        XCTAssertEqual(owner.contentMaxSize, contentMaxSize)
        XCTAssertNil(owner.delegate)
        XCTAssertEqual(other.styleMask, otherStyle)
        XCTAssertFalse(other.isResizable)
        XCTAssertFalse(bridge.acceptsFirstResponder)
        XCTAssertFalse(bridge.isAccessibilityElement())
        XCTAssertNil(bridge.hitTest(.zero))
    }

    func testDetachedBridgeSkipsOldWindowAndNeverEnablesPanelResizing() async {
        let previous = NSWindow(contentRect: NSRect(x: 40, y: 50, width: 760, height: 540),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: NSRect(x: 40, y: 50, width: 320, height: 190),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        previous.isReleasedWhenClosed = false
        panel.isReleasedWhenClosed = false
        defer { previous.close(); panel.close() }
        let previousStyle = previous.styleMask
        let panelStyle = panel.styleMask
        let bridge = SettingsWindowResizeView(frame: .zero)
        previous.contentView?.addSubview(bridge)
        bridge.removeFromSuperview()
        panel.contentView?.addSubview(bridge)
        await drainAttachmentCallbacks()
        XCTAssertEqual(previous.styleMask, previousStyle,
                       "A deferred callback must not mutate its former owning window")
        XCTAssertEqual(panel.styleMask, panelStyle,
                       "A bridge accidentally hosted in NSPanel must not resize it")
        bridge.removeFromSuperview()
        bridge.requestOwnedWindowResizability()
        await drainAttachmentCallbacks()
        XCTAssertEqual(previous.styleMask, previousStyle)
        XCTAssertEqual(panel.styleMask, panelStyle)
    }

    private func drainAttachmentCallbacks() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}


@MainActor
final class NativeMenuSummaryContrastTests: XCTestCase {
    private final class Target: NSObject {
        var calls = 0
        @objc func didSelectMenuCommand(_ sender: NSMenuItem) { calls += 1 }
    }

    private let expected = NativeMenuSummaryContrast.Fingerprint(
        summary: ["等待上班", "今日已获得 ¥0.00"], panelTitle: "显示收入面板",
        businessTitle: "打卡上班", loginStatusTitle: nil)

    private func fixture(_ target: Target) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let titles: [String?] = expected.summary.map { Optional($0) } +
            [nil, "显示收入面板", "打卡上班", "打开设置…", nil,
             "始终置顶", "全屏应用时隐藏", "登录时启动", nil, "退出可视收入打卡机"]
        for (index, title) in titles.enumerated() {
            guard let title else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: #selector(Target.didSelectMenuCommand(_:)), keyEquivalent: "")
            item.target = target
            item.isEnabled = index > 1 && title != "打卡上班"
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 13), .kern: 0.2
            ])
            if title == "显示收入面板" { item.keyEquivalent = "i"; item.keyEquivalentModifierMask = [.option, .command] }
            if title == "打开设置…" { item.keyEquivalent = ","; item.keyEquivalentModifierMask = .command }
            if title == "退出可视收入打卡机" { item.keyEquivalent = "q"; item.keyEquivalentModifierMask = .command }
            menu.addItem(item)
        }
        return menu
    }

    private func resolvedLabel(in menu: NSMenu) -> NSColor? {
        var result: NSColor?
        menu.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let value = NSColor.labelColor.usingColorSpace(.sRGB) {
                result = NSColor(srgbRed: value.redComponent, green: value.greenComponent,
                                 blue: value.blueComponent, alpha: value.alphaComponent)
            }
        }
        return result
    }

    private func earningFixture(_ target: Target, detail: String,
                                warning: String? = nil) -> NSMenu {
        let menu = fixture(target)
        menu.items[0].title = "计薪中"
        menu.items[1].title = detail
        menu.items[4].title = "打卡下班"
        menu.items[4].attributedTitle = NSAttributedString(string: "打卡下班")
        menu.items[4].isEnabled = true
        for item in menu.items.prefix(2) {
            item.action = nil
            item.target = nil
            item.attributedTitle = NSAttributedString(string: item.title)
        }
        if let warning {
            let item = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 2)
        }
        return menu
    }

    private func earningFingerprint(detail: String, warning: String? = nil) -> NativeMenuSummaryContrast.Fingerprint {
        .init(summary: ["计薪中", detail] + (warning.map { [$0] } ?? []),
              panelTitle: expected.panelTitle, businessTitle: "打卡下班", loginStatusTitle: nil)
    }

    func testFirstOpenEarningDetailAcceptsOnlyCanonicalDynamicDriftAndDisplaysNativeTitle() throws {
        let target = Target()
        let sampled = "今日已获得 ¥999,999.980 · 距离下班 06:00:00"
        let rendered = "今日已获得 ¥999,999.990 · 距离下班 05:59:58"
        for warning in [nil, "设置需要修复"] as [String?] {
            let menu = earningFixture(target, detail: rendered, warning: warning)
            let expected = earningFingerprint(detail: sampled, warning: warning)
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected,
                informationalRows: true), warning == nil ? 2 : 3)
            XCTAssertEqual((menu.items[1].view as? NativeMenuInformationRow)?.textField.stringValue, rendered)
            XCTAssertEqual((menu.items[1].view as? NativeMenuInformationRow)?.textField.accessibilityValue() as? String,
                           rendered)
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected,
                informationalRows: true), 0)
            XCTAssertTrue(menu.items.prefix(warning == nil ? 2 : 3).allSatisfy { !$0.isEnabled && $0.action == nil })
        }
        XCTAssertEqual(target.calls, 0)
    }

    func testDynamicDetailDoesNotBroadenLegacyColorOnlyMatching() {
        let target = Target()
        let rendered = "今日已获得 ¥999,999.990 · 距离下班 05:59:58"
        let sampled = "今日已获得 ¥999,999.980 · 距离下班 06:00:00"
        let menu = earningFixture(target, detail: rendered)
        let before = menu.items[0].attributedTitle
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu,
            matching: earningFingerprint(detail: sampled), informationalRows: false), 0)
        XCTAssertEqual(menu.items[0].attributedTitle, before)
        XCTAssertTrue(menu.items.prefix(2).allSatisfy { $0.view == nil })
    }

    func testDynamicDetailUpdatesExistingRowFromActualMenuTitle() throws {
        let center = NotificationCenter()
        let target = Target()
        let first = "今日已获得 ¥999,999.980 · 距离下班 06:00:00"
        let second = "今日已获得 ¥999,999.990 · 距离下班 05:59:58"
        let third = "今日已获得 ¥1,000,000.001 · 距离下班 05:59:57"
        let menu = earningFixture(target, detail: second)
        let bridge = NativeMenuSummaryContrast(center: center) { [self] in earningFingerprint(detail: first) }
        bridge.start()
        defer { bridge.stop() }
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        let row = try XCTUnwrap(menu.items[1].view as? NativeMenuInformationRow)
        XCTAssertEqual(row.textField.stringValue, second)
        menu.items[1].title = third
        menu.items[1].attributedTitle = NSAttributedString(string: third)
        center.post(name: NSMenu.didChangeItemNotification, object: menu)
        XCTAssertTrue(menu.items[1].view === row)
        XCTAssertEqual(row.textField.stringValue, third)
        center.post(name: NSMenu.didChangeItemNotification, object: menu)
        XCTAssertTrue(menu.items[1].view === row)
        XCTAssertEqual(row.textField.stringValue, third)
        XCTAssertEqual(target.calls, 0)
    }

    func testDynamicDetailRejectsMalformedOrCrossStateWithoutPartialMutation() {
        let target = Target()
        let sampled = "今日已获得 ¥999,999.980 · 距离下班 06:00:00"
        let invalid = ["今日已获得 ¥0999,999.990 · 距离下班 05:59:58",
                       "今日已获得 ¥99999.990 · 距离下班 05:59:58",
                       "今日已获得 ¥999,999.99 · 距离下班 05:59:58",
                       "今日已获得 ¥999,999.990 · 距离下班 05:60:58",
                       "今日已获得 ¥999,999.990 · 距离下班 05:59:58\n",
                       "今日已获得 ¥999,999.990 · 距离下班 05:59:58…",
                       "今日已获得 ¥-999,999.990 · 距离下班 05:59:58"]
        for rendered in invalid {
            let menu = earningFixture(target, detail: rendered)
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu,
                matching: earningFingerprint(detail: sampled), informationalRows: true), 0,
                rendered)
            XCTAssertTrue(menu.items.prefix(2).allSatisfy { $0.view == nil })
        }
        let rendered = "今日已获得 ¥999,999.990 · 距离下班 05:59:58"
        let menu = earningFixture(target, detail: rendered)
        let wrongStates = [NativeMenuSummaryContrast.Fingerprint(summary: ["已打卡 · 等待开工", sampled],
            panelTitle: expected.panelTitle, businessTitle: "打卡下班", loginStatusTitle: nil),
            earningFingerprint(detail: "今日已获得 ¥999,999.980 · 距离开始 06:00:00")]
        for wrong in wrongStates {
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: wrong,
                informationalRows: true), 0)
            XCTAssertTrue(menu.items.prefix(2).allSatisfy { $0.view == nil })
        }
        menu.items[5].keyEquivalent = "x"
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu,
            matching: earningFingerprint(detail: sampled), informationalRows: true), 0)
        XCTAssertTrue(menu.items.prefix(2).allSatisfy { $0.view == nil })
        let warningMenu = earningFixture(target, detail: rendered, warning: "别的警告")
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: warningMenu,
            matching: earningFingerprint(detail: sampled, warning: "别的警告"),
            informationalRows: true), 0)
        XCTAssertTrue(warningMenu.items.prefix(3).allSatisfy { $0.view == nil })
        XCTAssertEqual(target.calls, 0)
    }

    func testResolvedSummaryColorTracksMenuAppearanceWithoutChangingDisabledSemantics() throws {
        let target = Target()
        let menu = fixture(target)
        var observed: [NSColor] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            menu.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected), 2)
            let color = try XCTUnwrap(menu.items[0].attributedTitle?.attribute(
                .foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(color.colorSpace, .sRGB)
            XCTAssertEqual(color, resolvedLabel(in: menu))
            observed.append(color)
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected), 0)
            XCTAssertTrue(menu.items.prefix(2).allSatisfy { !$0.isEnabled })
            XCTAssertEqual(target.calls, 0)
        }
        XCTAssertNotEqual(observed[0], observed[1])
    }

    func testOnlyDisabledSummaryForegroundChangesAndSecondPassIsIdempotent() throws {
        let target = Target()
        let menu = fixture(target)
        let first = menu.items[0]
        let marker = NSObject()
        first.representedObject = marker
        let before = try XCTUnwrap(first.attributedTitle)
        let suffix = menu.items[4].attributedTitle
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected), 2)
        XCTAssertEqual(first.attributedTitle?.string, expected.summary[0])
        XCTAssertEqual(first.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, resolvedLabel(in: menu))
        XCTAssertEqual(first.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       before.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(first.attributedTitle?.attribute(.kern, at: 0, effectiveRange: nil) as? Double, 0.2)
        XCTAssertFalse(first.isEnabled)
        XCTAssertEqual(first.action, #selector(Target.didSelectMenuCommand(_:)))
        XCTAssertTrue(first.target === target)
        XCTAssertTrue(first.representedObject as? NSObject === marker)
        XCTAssertEqual(first.state, .off)
        XCTAssertEqual(first.keyEquivalent, "")
        XCTAssertEqual(menu.items[4].attributedTitle, suffix)
        XCTAssertFalse(menu.items[4].isEnabled)
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected), 0)
        XCTAssertEqual(target.calls, 0)
    }

    func testMismatchNeverPartiallyChangesSummary() {
        let target = Target()
        let mutations: [(NSMenu) -> Void] = [
            { $0.items.last?.title = "其他应用" },
            { $0.items[3].keyEquivalent = "x" },
            { $0.items[0].isEnabled = true },
            { $0.items[1].title = "stale summary" },
            { $0.items[3].submenu = NSMenu() }
        ]
        for mutate in mutations {
            let menu = fixture(target)
            mutate(menu)
            let before = menu.items[0].attributedTitle
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected), 0)
            XCTAssertEqual(menu.items[0].attributedTitle, before)
        }
        XCTAssertEqual(target.calls, 0)
    }

    func testObserverOnlyRespondsWhileStartedAndDoesNotDuplicateRegistration() throws {
        let center = NotificationCenter()
        let target = Target()
        let menu = fixture(target)
        for item in menu.items.prefix(2) { item.action = nil; item.target = nil }
        var providerCalls = 0
        var current = expected
        let bridge = NativeMenuSummaryContrast(center: center) {
            providerCalls += 1
            return current
        }
        bridge.start()
        bridge.start()
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(providerCalls, 0)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertEqual(providerCalls, 1)
        let first = try XCTUnwrap(menu.items[0].view as? NativeMenuInformationRow)
        let second = try XCTUnwrap(menu.items[1].view as? NativeMenuInformationRow)
        XCTAssertEqual(first.textField.stringValue, expected.summary[0])
        XCTAssertEqual(second.textField.stringValue, expected.summary[1])
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertEqual(providerCalls, 2)
        XCTAssertTrue(menu.items[0].view === first)
        XCTAssertTrue(menu.items[1].view === second)
        let updatedTitle = "今日已获得 ¥123456789.123 · 距离下班 08:00:00"
        menu.items[1].title = updatedTitle
        menu.items[1].attributedTitle = nil
        current = .init(summary: [expected.summary[0], updatedTitle],
                        panelTitle: expected.panelTitle, businessTitle: expected.businessTitle,
                        loginStatusTitle: expected.loginStatusTitle)
        center.post(name: NSMenu.didChangeItemNotification, object: menu)
        XCTAssertEqual(providerCalls, 3)
        XCTAssertTrue(menu.items[1].view === second)
        XCTAssertEqual(second.textField.stringValue, updatedTitle)
        bridge.stop()
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didChangeItemNotification, object: menu)
        XCTAssertEqual(providerCalls, 3)
        XCTAssertEqual(target.calls, 0)
    }

    func testInformationalRowsPreserveCommandsAndHaveNoInputOrFocusTarget() throws {
        let target = Target()
        let menu = fixture(target)
        for item in menu.items.prefix(2) { item.action = nil; item.target = nil }
        let items = menu.items
        let titles = items.map(\.title)
        let enabled = items.map(\.isEnabled)
        let actions = items.map(\.action)
        let attributed = items.map(\.attributedTitle)
        let keys = items.map(\.keyEquivalent)
        let modifiers = items.map(\.keyEquivalentModifierMask)
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected, informationalRows: true), 2)
        XCTAssertEqual(menu.items, items)
        XCTAssertEqual(menu.items.map(\.title), titles)
        XCTAssertEqual(menu.items.map(\.isEnabled), enabled)
        XCTAssertEqual(menu.items.map(\.action), actions)
        XCTAssertEqual(menu.items.map(\.attributedTitle), attributed)
        XCTAssertEqual(menu.items.map(\.keyEquivalent), keys)
        XCTAssertEqual(menu.items.map(\.keyEquivalentModifierMask), modifiers)
        for (index, item) in menu.items.prefix(2).enumerated() {
            let row = try XCTUnwrap(item.view as? NativeMenuInformationRow)
            row.layoutSubtreeIfNeeded()
            XCTAssertEqual(row.textField.stringValue, expected.summary[index])
            XCTAssertEqual(row.textField.font, menu.font)
            XCTAssertFalse(row.acceptsFirstResponder)
            XCTAssertFalse(row.textField.acceptsFirstResponder)
            XCTAssertFalse(row.textField.isEditable)
            XCTAssertFalse(row.textField.isSelectable)
            XCTAssertNil(row.hitTest(NSPoint(x: row.bounds.midX, y: row.bounds.midY)))
            XCTAssertFalse(row.isAccessibilityElement())
            XCTAssertEqual(row.textField.accessibilityRole(), .staticText)
            XCTAssertEqual(row.textField.accessibilityValue() as? String, expected.summary[index])
            XCTAssertFalse(row.textField.accessibilityPerformPress())
            XCTAssertTrue(row.bounds.contains(row.textField.frame))
            XCTAssertNil(item.action)
            XCTAssertNil(item.target)
        }
        XCTAssertTrue(menu.items.dropFirst(2).allSatisfy { $0.view == nil })
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected, informationalRows: true), 0)
        XCTAssertEqual(target.calls, 0)
        // A pre-existing real command still invokes exactly its original target.
        menu.performActionForItem(at: 3)
        XCTAssertEqual(target.calls, 1)
    }

    func testInformationalRowsUpdateTextAndRenderExactThirdWarningWithoutPartialMutation() throws {
        let target = Target()
        let menu = fixture(target)
        for item in menu.items.prefix(2) { item.action = nil; item.target = nil }
        let warning = NSMenuItem(title: "设置需要修复", action: nil, keyEquivalent: "")
        warning.isEnabled = false
        warning.attributedTitle = NSAttributedString(string: warning.title, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        let originalWarningTitle = warning.attributedTitle
        menu.insertItem(warning, at: 2)
        let withWarning = NativeMenuSummaryContrast.Fingerprint(summary: expected.summary + [warning.title],
            panelTitle: expected.panelTitle, businessTitle: expected.businessTitle, loginStatusTitle: nil)
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: withWarning, informationalRows: true), 3)
        XCTAssertEqual(warning.attributedTitle, originalWarningTitle)
        let warningRow = try XCTUnwrap(warning.view as? NativeMenuInformationRow)
        XCTAssertEqual(warningRow.textField.stringValue, warning.title)
        XCTAssertEqual(warningRow.textField.accessibilityRole(), .staticText)
        XCTAssertEqual(warningRow.textField.accessibilityValue() as? String, warning.title)
        XCTAssertFalse(warningRow.acceptsFirstResponder)
        XCTAssertFalse(warningRow.textField.acceptsFirstResponder)
        XCTAssertNil(warningRow.hitTest(NSPoint(x: warningRow.bounds.midX, y: warningRow.bounds.midY)))
        XCTAssertFalse(warningRow.textField.accessibilityPerformPress())
        XCTAssertFalse(warning.isEnabled)
        XCTAssertNil(warning.action)
        let row = try XCTUnwrap(menu.items[1].view as? NativeMenuInformationRow)
        let originalWidth = row.frame.width
        let updatedTitle = "今日已获得 ¥123456789.123 · 距离下班 08:00:00"
        menu.items[1].title = updatedTitle
        menu.items[1].attributedTitle = NSAttributedString(string: updatedTitle)
        // Stale fingerprints must not replace visible informational content.
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: withWarning, informationalRows: true), 0)
        XCTAssertEqual(row.textField.stringValue, expected.summary[1])
        let updated = NativeMenuSummaryContrast.Fingerprint(summary: [expected.summary[0], updatedTitle, warning.title],
            panelTitle: expected.panelTitle, businessTitle: expected.businessTitle, loginStatusTitle: nil)
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: updated, informationalRows: true), 1)
        XCTAssertTrue(menu.items[1].view === row)
        XCTAssertEqual(row.textField.stringValue, updatedTitle)
        XCTAssertGreaterThan(row.frame.width, originalWidth)
        row.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(row.textField.frame.width,
            ceil((updatedTitle as NSString).size(withAttributes: [.font: menu.font]).width))
        XCTAssertTrue(warning.view === warningRow)
        XCTAssertEqual(warning.attributedTitle, originalWarningTitle)
        XCTAssertFalse(warning.isEnabled)
        XCTAssertNil(warning.action)
        XCTAssertEqual(target.calls, 0)
    }

    func testInformationalRowsRejectInteractiveOrForeignViewBeforeAnyChanges() {
        let target = Target()
        let mutations: [(NSMenu) -> Void] = [
            { $0.items[1].action = #selector(Target.didSelectMenuCommand(_:)); $0.items[1].target = target },
            { $0.items[1].view = NSView() },
            { $0.items.last?.title = "unrelated menu" },
            { $0.items[1].isEnabled = true }
        ]
        for mutation in mutations {
            let menu = fixture(target)
            for item in menu.items.prefix(2) { item.action = nil; item.target = nil }
            mutation(menu)
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected, informationalRows: true), 0)
            XCTAssertNil(menu.items[0].view)
        }
        for (thirdTitle, hasAction) in [("其他提示", false), ("设置需要修复", true)] {
            let menu = fixture(target)
            for item in menu.items.prefix(2) { item.action = nil; item.target = nil }
            let warning = NSMenuItem(title: thirdTitle,
                action: hasAction ? #selector(Target.didSelectMenuCommand(_:)) : nil,
                keyEquivalent: "")
            warning.target = hasAction ? target : nil
            warning.isEnabled = false
            menu.insertItem(warning, at: 2)
            let fingerprint = NativeMenuSummaryContrast.Fingerprint(
                summary: expected.summary + [thirdTitle], panelTitle: expected.panelTitle,
                businessTitle: expected.businessTitle, loginStatusTitle: nil)
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: fingerprint,
                informationalRows: true), 0)
            XCTAssertTrue(menu.items.prefix(3).allSatisfy { $0.view == nil })
        }
        XCTAssertEqual(target.calls, 0)
    }

    func testInformationalAppearanceRequiresCompleteMatchAndExcludesMainMenu() throws {
        let target = Target()
        let original = try XCTUnwrap(NSAppearance(named: .aqua))
        let requested = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let oldMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMainMenu }
        for isMainMenu in [false, true] {
            let menu = fixture(target)
            for item in menu.items.prefix(2) { item.action = nil; item.target = nil }
            menu.appearance = original
            if isMainMenu { NSApp.mainMenu = menu }
            else { menu.items.last?.title = "unrelated menu" }
            XCTAssertEqual(NativeMenuSummaryContrast.apply(to: menu, matching: expected,
                informationalRows: true, isolatedAppearance: requested), 0)
            XCTAssertTrue(menu.appearance === original)
            XCTAssertTrue(menu.items.allSatisfy { $0.view == nil })
        }
        NSApp.mainMenu = oldMainMenu
#if DEBUG && STAGE9_ISOLATED_TEST_BUILD
        let matched = fixture(target)
        for item in matched.items.prefix(2) { item.action = nil; item.target = nil }
        matched.appearance = original
        XCTAssertEqual(NativeMenuSummaryContrast.apply(to: matched, matching: expected,
            informationalRows: true, isolatedAppearance: requested), 2)
        XCTAssertTrue(matched.appearance === requested)
#endif
        XCTAssertEqual(target.calls, 0)
    }

    func testInformationalRowArchiveCopyKeepsOneStaticLabelAndNativeFont() throws {
        let row = NativeMenuInformationRow(title: "今日已获得 ¥123.456", font: NSFont.menuFont(ofSize: 0))
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: row, requiringSecureCoding: false)
        let copy = try XCTUnwrap(NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(bytes) as? NativeMenuInformationRow)
        XCTAssertEqual(copy.subviews.count, 1)
        XCTAssertEqual(copy.textField.stringValue, row.textField.stringValue)
        XCTAssertEqual(copy.textField.font, row.textField.font)
        XCTAssertFalse(copy.textField.isSelectable)
        XCTAssertFalse(copy.textField.acceptsFirstResponder)
        XCTAssertNil(copy.hitTest(NSPoint(x: 20, y: 10)))
    }
}
