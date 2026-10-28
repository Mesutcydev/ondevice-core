import SwiftUI
import OnDeviceUI

struct AssistantToolResultStrip: View {
    let messages: [ChatMessage]
    @Binding var isExpanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ODAgentLabel()
            ODToolActivityGroup(events: messages.compactMap { message in
                guard let payload = AssistantActivity.parseToolResult(message.content) else { return nil }
                let status: ODToolEvent.Status
                switch AssistantActivity.toolStatus(result: payload.result) {
                case .success: status = .success
                case .failure: status = .failure
                case .cancelled: status = .cancelled
                }
                return ODToolEvent(id: message.id,
                    title: AssistantActivity.toolPillTitle(name: payload.name, result: payload.result),
                    detail: payload.result, status: status)
            }, isExpanded: $isExpanded)
        }
        .padding(.horizontal, ODLayout.pageInset)
    }
}
