import SwiftUI
import OnDeviceUI

// MARK: - MicDictationButton
// Hold-to-talk mic button. Tap-and-hold (or single-tap to toggle) starts
// speech recognition; the transcript is written into the bound text.
//
// Use it next to a TextField/TextEditor:
//   MicDictationButton(text: $inputText)

struct MicDictationButton: View {
    @Binding var text: String
    @StateObject private var dictation = SpeechDictationService()
    @State private var preCaptureText: String = ""    // baseline before this session
    @State private var permissionsRequested = false
    @State private var showDeniedSheet = false
    @State private var authorizationRequestID = UUID()

    @Environment(\.koduTheme) private var T

    /// When true, show the recording state inline as a chip; otherwise toggle the icon only.
    var compact: Bool = false
    var resetID: UUID? = nil
    var showsTitle = false

    var body: some View {
        Group {
        if dictation.supportsLocalDictation {
        Button {
            HapticManager.impact(.light)
            let requestID = authorizationRequestID
            ODBridge.shared.store.requestExclusiveOperation("Dictation") { Task { await toggleRecording(requestID: requestID) } }
        } label: {
            if showsTitle {
                Label(dictation.isRecording ? "Stop dictation" : "Start dictation",
                      systemImage: dictation.isRecording ? "stop.circle" : "mic")
                    .frame(minHeight: ODLayout.minimumHit)
            } else { iconLabel }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate message")
        } else if showsTitle {
            Text("On-device dictation is unavailable for the current language.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        }
        .onDisappear { authorizationRequestID = UUID(); dictation.stop() }
        .onChange(of: resetID) { _, _ in authorizationRequestID = UUID(); dictation.stop() }
        .alert("Microphone access needed",
               isPresented: $showDeniedSheet) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable microphone and speech recognition for OnDevice in Settings → Privacy.")
        }
    }

    // MARK: - Label

    private var iconLabel: some View {
        Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
            .font(.title3)
            .foregroundStyle(dictation.isRecording ? ODPalette.red : ODPalette.text)
            .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
            .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func toggleRecording(requestID: UUID) async {
        if dictation.isRecording {
            dictation.stop()
            return
        }

        // Request permissions on first use
        if !permissionsRequested {
            permissionsRequested = true
            let ok = await dictation.requestAuthorization()
            guard authorizationRequestID == requestID else { return }
            if !ok {
                showDeniedSheet = true
                return
            }
        } else if !dictation.isAuthorized {
            showDeniedSheet = true
            return
        }

        guard dictation.supportsLocalDictation else {
            ToastCenter.shared.error("Speech recognition unavailable",
                                      detail: dictation.lastError ?? "Try again in a moment.")
            return
        }

        guard authorizationRequestID == requestID else { return }
        preCaptureText = text
        do {
            try dictation.start { transcript, isFinal in
                let glue: String = preCaptureText.isEmpty
                    ? ""
                    : (preCaptureText.hasSuffix(" ") ? "" : " ")
                text = preCaptureText + glue + transcript
                if isFinal { HapticManager.impact(.light) }
            }
        } catch {
            ToastCenter.shared.error("Couldn't start dictation",
                                      detail: error.localizedDescription)
        }
    }
}
