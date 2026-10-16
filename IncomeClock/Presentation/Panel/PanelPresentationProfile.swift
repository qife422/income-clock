import CoreGraphics
import Foundation

struct PanelPresentationProfile: Equatable, Sendable {
    let id: String
    let contentSize: CGSize
    let contentSafeArea: CGRect
    let primaryDragRegion: CGRect
    let defaultEdgeOffset: CGFloat

    var externalPresentationSize: CGSize { contentSize }
}

struct PanelPresentationProfileRegistry: Sendable {
    static let standardProfileID = "standard.panel.320x190.v1"

    private let profilesByID: [String: PanelPresentationProfile]

    init(profiles: [PanelPresentationProfile] = [.standard]) {
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func profile(id: String) -> PanelPresentationProfile? {
        profilesByID[id]
    }

    var standard: PanelPresentationProfile {
        guard let profile = profile(id: Self.standardProfileID) else {
            preconditionFailure("The standard panel profile must be registered")
        }
        return profile
    }
}

extension PanelPresentationProfile {
    static let standard = PanelPresentationProfile(
        id: PanelPresentationProfileRegistry.standardProfileID,
        contentSize: CGSize(width: 320, height: 190),
        contentSafeArea: CGRect(x: 12, y: 8, width: 296, height: 172),
        primaryDragRegion: CGRect(x: 12, y: 8, width: 232, height: 28),
        defaultEdgeOffset: 20
    )
}
