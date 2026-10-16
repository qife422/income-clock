import SwiftUI

struct EmptyPanelView: View {
    @ObservedObject var businessStore: BusinessStore
    let profile: PanelPresentationProfile

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .frame(width: profile.contentSize.width, height: profile.contentSize.height)
            .accessibilityHidden(true)
            .environment(\.isEnabled, businessStore.viewState != nil)
    }
}
