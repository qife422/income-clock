import AppKit
import CoreGraphics

struct PanelScreenDescriptor: Equatable, Sendable {
    let displayUUID: String
    let frame: CGRect
    let visibleFrame: CGRect
    let isMain: Bool
}

protocol PanelScreenProviding: AnyObject {
    var screens: [PanelScreenDescriptor] { get }
    var mainScreen: PanelScreenDescriptor? { get }
}

final class SystemPanelScreenProvider: PanelScreenProviding {
    var screens: [PanelScreenDescriptor] {
        NSScreen.screens.compactMap(Self.descriptor)
    }

    var mainScreen: PanelScreenDescriptor? {
        screens.first(where: \.isMain) ?? screens.first
    }

    private static func descriptor(for screen: NSScreen) -> PanelScreenDescriptor? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return PanelScreenDescriptor(
            displayUUID: CFUUIDCreateString(nil, uuid) as String,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isMain: CGDisplayIsMain(displayID) != 0
        )
    }
}

struct PanelPlacementController: Sendable {
    func defaultPlacement(
        on screen: PanelScreenDescriptor,
        profile: PanelPresentationProfile
    ) -> PanelPlacementRecord {
        placement(
            on: screen,
            corner: .bottomRight,
            xOffset: profile.defaultEdgeOffset,
            yOffset: profile.defaultEdgeOffset,
            profile: profile
        )
    }

    func restoredPlacement(
        _ saved: PanelPlacementRecord?,
        screens: [PanelScreenDescriptor],
        mainScreen: PanelScreenDescriptor?,
        profile: PanelPresentationProfile
    ) -> PanelPlacementRecord? {
        guard let mainScreen = mainScreen ?? screens.first else { return nil }
        guard let saved,
              let screen = screens.first(where: { $0.displayUUID == saved.displayUUID }) else {
            return defaultPlacement(on: mainScreen, profile: profile)
        }
        return placement(
            on: screen,
            corner: saved.snapCorner,
            xOffset: max(0, saved.xOffset),
            yOffset: max(0, saved.yOffset),
            profile: profile
        )
    }

    func snappedPlacement(
        for draggedFrame: CGRect,
        screens: [PanelScreenDescriptor],
        mainScreen: PanelScreenDescriptor?,
        profile: PanelPresentationProfile
    ) -> PanelPlacementRecord? {
        guard let screen = destinationScreen(
            for: draggedFrame,
            screens: screens,
            mainScreen: mainScreen
        ) else { return nil }
        let visible = screen.visibleFrame
        let center = CGPoint(x: draggedFrame.midX, y: draggedFrame.midY)
        let horizontalRight = center.x >= visible.midX
        let verticalTop = center.y >= visible.midY
        let corner: PanelSnapCorner
        switch (horizontalRight, verticalTop) {
        case (false, true): corner = .topLeft
        case (true, true): corner = .topRight
        case (false, false): corner = .bottomLeft
        case (true, false): corner = .bottomRight
        }
        return placement(
            on: screen,
            corner: corner,
            xOffset: profile.defaultEdgeOffset,
            yOffset: profile.defaultEdgeOffset,
            profile: profile
        )
    }

    func constrainedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = frame.width
        let height = frame.height
        let minX = visibleFrame.minX
        let maxX = max(visibleFrame.maxX - width, minX)
        let minY = visibleFrame.minY
        let maxY = max(visibleFrame.maxY - height, minY)
        return CGRect(
            x: min(max(frame.minX, minX), maxX),
            y: min(max(frame.minY, minY), maxY),
            width: width,
            height: height
        )
    }

    private func placement(
        on screen: PanelScreenDescriptor,
        corner: PanelSnapCorner,
        xOffset: CGFloat,
        yOffset: CGFloat,
        profile: PanelPresentationProfile
    ) -> PanelPlacementRecord {
        let visible = screen.visibleFrame
        let size = profile.externalPresentationSize
        let desiredOrigin: CGPoint
        switch corner {
        case .topLeft:
            desiredOrigin = CGPoint(
                x: visible.minX + xOffset,
                y: visible.maxY - size.height - yOffset
            )
        case .topRight:
            desiredOrigin = CGPoint(
                x: visible.maxX - size.width - xOffset,
                y: visible.maxY - size.height - yOffset
            )
        case .bottomLeft:
            desiredOrigin = CGPoint(
                x: visible.minX + xOffset,
                y: visible.minY + yOffset
            )
        case .bottomRight:
            desiredOrigin = CGPoint(
                x: visible.maxX - size.width - xOffset,
                y: visible.minY + yOffset
            )
        }
        let frame = constrainedFrame(
            CGRect(origin: desiredOrigin, size: size),
            to: visible
        )
        let effectiveXOffset: CGFloat
        let effectiveYOffset: CGFloat
        switch corner {
        case .topLeft:
            effectiveXOffset = frame.minX - visible.minX
            effectiveYOffset = visible.maxY - frame.maxY
        case .topRight:
            effectiveXOffset = visible.maxX - frame.maxX
            effectiveYOffset = visible.maxY - frame.maxY
        case .bottomLeft:
            effectiveXOffset = frame.minX - visible.minX
            effectiveYOffset = frame.minY - visible.minY
        case .bottomRight:
            effectiveXOffset = visible.maxX - frame.maxX
            effectiveYOffset = frame.minY - visible.minY
        }
        return PanelPlacementRecord(
            displayUUID: screen.displayUUID,
            snapCorner: corner,
            xOffset: Double(effectiveXOffset),
            yOffset: Double(effectiveYOffset),
            constrainedFrame: PersistedPanelFrame(
                x: Double(frame.origin.x),
                y: Double(frame.origin.y),
                width: Double(frame.width),
                height: Double(frame.height)
            )
        )
    }

    private func destinationScreen(
        for frame: CGRect,
        screens: [PanelScreenDescriptor],
        mainScreen: PanelScreenDescriptor?
    ) -> PanelScreenDescriptor? {
        let intersecting = screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
        if let intersecting,
           intersecting.frame.intersection(frame).area > 0 {
            return intersecting
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min {
            $0.frame.squaredDistance(to: center) < $1.frame.squaredDistance(to: center)
        } ?? mainScreen
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    func squaredDistance(to point: CGPoint) -> CGFloat {
        let nearestX = min(max(point.x, minX), maxX)
        let nearestY = min(max(point.y, minY), maxY)
        let dx = point.x - nearestX
        let dy = point.y - nearestY
        return dx * dx + dy * dy
    }
}

extension PersistedPanelFrame {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
