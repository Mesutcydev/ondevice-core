import Combine
import SwiftUI
import OnDeviceUI

/// Bridges selection to host-owned lifecycle effects without observing every
/// streaming update in ODStore. The outer ODBridge does not publish its nested
/// store's changes, so the host must subscribe to the selections themselves.
struct WorkbenchSelectionObserver: ViewModifier {
    let store: ODStore
    let onTabSelection: (ODTab) -> Void
    let onCameraModeSelection: (ODLensMode) -> Void
    var onLensVisibility: (Bool) -> Void = { _ in }

    func body(content: Content) -> some View {
        content
            .onReceive(store.$selectedTab.removeDuplicates()) { tab in
                onTabSelection(tab)
            }
            .onReceive(Publishers.CombineLatest4(store.$selectedTab, store.$conversationsPresented,
                                                 store.$voiceSessionPresented,
                                                 Publishers.CombineLatest3(store.$secondaryRoute, store.$lensResultPresented, store.$voiceSessionReturnPending)
                                                    .map { route, result, returning in route == nil && !result && !returning })
                .map { tab, drawer, voice, clearModal in tab == .lens && !drawer && !voice && clearModal }
                .removeDuplicates()) { visible in
                    onLensVisibility(visible)
                }
            // Preserve the saved prompt/result on mount. Only actual mode
            // changes should reset the host's analysis state.
            .onReceive(store.$cameraMode.removeDuplicates().dropFirst()) { mode in
                onCameraModeSelection(mode)
            }
    }
}
