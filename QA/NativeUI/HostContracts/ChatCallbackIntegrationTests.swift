import XCTest
import SwiftUI
@testable import NativeUIReview

/// Exercises SwiftUI's installed State storage, not just value-type request equality.
@MainActor
final class ChatCallbackIntegrationTests: XCTestCase {
    func testStreamCallbackSurvivesSendStateMutationAndRender() async throws {
        let driver = ChatCallbackDriver()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: ChatCallbackProbe(driver: driver))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        try XCTUnwrap(driver.send)()
        try await Task.sleep(for: .milliseconds(150))
        try XCTUnwrap(driver.token)("Hello")
        try await Task.sleep(for: .milliseconds(150))
        try XCTUnwrap(driver.complete)()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(driver.acceptedTokens, 1)
        XCTAssertEqual(driver.completed, 1)
        XCTAssertEqual(driver.renderedReply, "Hello")
        XCTAssertFalse(driver.renderedStreaming)
    }
}

@MainActor
private final class ChatCallbackDriver {
    var send: (() -> Void)?
    var token: ((String) -> Void)?
    var complete: (() -> Void)?
    var acceptedTokens = 0
    var completed = 0
    var renderedReply = ""
    var renderedStreaming = false
}

private struct ChatCallbackProbe: View {
    let driver: ChatCallbackDriver
    @State private var operationID = UUID()
    @State private var conversationID: UUID?
    @State private var text = "Hey"
    @State private var reply = ""
    @State private var streaming = false

    var body: some View {
        VStack { Text(text); Text(reply); Text(streaming ? "Generating" : "Ready") }
            .onAppear { driver.send = send }
            .onChange(of: reply) { _, value in driver.renderedReply = value }
            .onChange(of: streaming) { _, value in driver.renderedStreaming = value }
    }

    private func send() {
        operationID = UUID()
        if conversationID == nil { conversationID = UUID() }
        let scope = ChatPresentationRequest(id: operationID, conversationID: conversationID!,
            draftRevision: 0, modelID: "local/model", draft: .init(text: text), attachmentIDs: [])
        text = ""
        streaming = true
        driver.token = { piece in
            guard scope.belongsTo(requestID: operationID, conversationID: conversationID, modelID: "local/model") else { return }
            driver.acceptedTokens += 1
            reply += piece
        }
        driver.complete = {
            guard scope.belongsTo(requestID: operationID, conversationID: conversationID, modelID: "local/model") else { return }
            driver.completed += 1
            streaming = false
        }
    }
}
