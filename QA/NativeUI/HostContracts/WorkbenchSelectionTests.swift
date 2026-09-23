import XCTest
import SwiftUI
import OnDeviceUI
@testable import NativeUIReview

@MainActor
final class WorkbenchSelectionTests: XCTestCase {
    func testBrowsingPreservesVoiceAndExclusiveActionsRequireConfirmation() {
        let store = ODStore(appearanceDefaults: nil)
        store.voiceSessionActive = true
        var actions: [String] = []
        store.onAction = { action in actions.append(String(describing: action)) }
        for destination in ODTab.allCases { store.selectedTab = destination }
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(store.voiceSessionActive)
        store.send(.loadModel("next"))
        XCTAssertTrue(store.interruptionConfirmationPresented)
        XCTAssertTrue(actions.isEmpty)
        store.cancelInterruption()
        XCTAssertTrue(actions.isEmpty)
        store.send(.loadModel("next"))
        store.confirmInterruption()
        XCTAssertEqual(actions, ["endVoiceSession", "loadModel(\"next\")"])
    }

    func testCaptureDemandCannotBeRevivedByLatePermissionOrForeground() {
        var demand = CaptureSessionDemand()
        demand.isRequested = true
        XCTAssertTrue(demand.shouldRun)
        demand.isForeground = false
        XCTAssertFalse(demand.shouldRun)
        demand.isRequested = false // leave Lens during suspension/permission prompt
        demand.isForeground = true // late foreground or permission completion
        XCTAssertFalse(demand.shouldRun)
        demand.isRequested = true
        XCTAssertTrue(demand.shouldRun)
    }

    func testSnippetsStripMarkdownWithoutGeneratingText() {
        XCTAssertEqual(ODPresentation.messagePreview("**Hello** [world](https://example.com)"), "Hello world")
        XCTAssertEqual(ODPresentation.messagePreview("![Diagram](attachment://local)"), "Image: Diagram")
        XCTAssertEqual(ODPresentation.messagePreview("# Heading\n- First item"), "Heading First item")
    }

    func testLensEntryExitAndReturnReachHostWithoutOuterBridgePublishing() async throws {
        let store = ODStore(appearanceDefaults: nil)
        let events = SelectionEvents()
        let host = mount(store: store, events: events)
        defer { host.isHidden = true }
        await settle()
        events.tabs.removeAll()

        for tab in [ODTab.lens, .voice, .lens, .chat, .models, .home] {
            store.selectedTab = tab
            await settle()
        }
        XCTAssertEqual(events.tabs, [.lens, .voice, .lens, .chat, .models, .home],
                       "The host must start and stop the camera even when only the nested store changes")
    }

    func testColdLaunchOnLensAndModeChangesReachHostOnlyOnce() async throws {
        let store = ODStore(appearanceDefaults: nil)
        store.selectedTab = .lens
        let events = SelectionEvents()
        let host = mount(store: store, events: events)
        defer { host.isHidden = true }
        await settle()
        XCTAssertEqual(events.tabs, [.lens], "A preselected Lens must start on mount")
        XCTAssertTrue(events.modes.isEmpty, "Mount must not clear the saved prompt or result")

        let mode = try XCTUnwrap(ODLensMode.allCases.first { $0 != store.cameraMode })
        store.cameraMode = mode
        await settle()
        store.cameraMode = mode
        store.selectedTab = .lens
        store.lensResultText = "Unrelated streaming update"
        await settle()
        XCTAssertEqual(events.modes, [mode])
        XCTAssertEqual(events.tabs, [.lens])
    }

    func testDrawerAndFullVoiceCoverReleaseLensVisibilityWithoutEndingVoice() async {
        let store = ODStore(appearanceDefaults: nil)
        store.selectedTab = .lens
        let events = SelectionEvents()
        let host = mount(store: store, events: events)
        defer { host.isHidden = true }
        await settle()
        store.conversationsPresented = true; await settle()
        store.conversationsPresented = false; await settle()
        store.voiceSessionActive = true
        store.voiceSessionPresented = true; await settle()
        store.voiceSessionPresented = false; await settle()
        store.lensResultPresented = true; await settle()
        store.lensResultPresented = false; await settle()
        store.selectedTab = .voice; await settle()
        XCTAssertEqual(events.visibility, [true, false, true, false, true, false, true, false])
        XCTAssertTrue(store.voiceSessionActive)
    }

    private func mount(store: ODStore, events: SelectionEvents) -> UIWindow {
        // Deliberately no @ObservedObject store or outer bridge publisher:
        // this is the production boundary that let the visible tab change
        // without running ContentView's camera lifecycle.
        let view = Color.clear.modifier(WorkbenchSelectionObserver(
            store: store,
            onTabSelection: { events.tabs.append($0) },
            onCameraModeSelection: { events.modes.append($0) },
            onLensVisibility: { events.visibility.append($0) }
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor
private final class SelectionEvents {
    var tabs: [ODTab] = []
    var modes: [ODLensMode] = []
    var visibility: [Bool] = []
}
