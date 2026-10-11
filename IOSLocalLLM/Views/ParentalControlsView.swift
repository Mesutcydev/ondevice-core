import SwiftUI

struct ParentalControlsView: View {
    @ObservedObject var controls: ParentalControlManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var confirmation = ""
    @State private var message: String?
    private enum PINField: Hashable { case current, new, confirmation }
    @FocusState private var focusedPIN: PINField?

    @MainActor
    init(controls: ParentalControlManager? = nil) { self.controls = controls ?? .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Parental controls", value: controls.isEnabled ? String(localized: "On") : String(localized: "Off"))
                LabeledContent("Image generation", value: controls.blocksImageGeneration ? String(localized: "Restricted") : String(localized: "Allowed"))
                    .accessibilityIdentifier("parent.images.status")
            } footer: {
                Text("The restriction applies to Image Studio and image requests made through chat tools. It does not filter generated content or control other apps. Use Screen Time for device-wide restrictions.")
            }
            if controls.storageUnavailable {
                Section {
                    Text(ParentalControlManager.Failure.storageUnavailable.localizedDescription)
                    Button("Retry secure storage") { controls.reload() }
                }
            } else {
                if controls.isEnabled {
                    Section("Parent PIN") {
                        SecureField("Current six-digit PIN", text: $currentPIN)
                            .focused($focusedPIN, equals: .current)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("parent.pin.current")
                        Button(controls.blocksImageGeneration ? "Allow image generation" : "Restrict image generation") {
                            perform { try controls.setImageRestriction(!controls.blocksImageGeneration, pin: currentPIN) }
                        }
                        .accessibilityIdentifier("parent.images.change")
                        Button("Turn off parental controls", role: .destructive) {
                            perform { try controls.remove(pin: currentPIN) }
                        }
                        .accessibilityIdentifier("parent.remove")
                    }
                }
                Section {
                    SecureField("New six-digit PIN", text: $newPIN)
                        .focused($focusedPIN, equals: .new)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("parent.pin.new")
                    SecureField("Confirm new PIN", text: $confirmation)
                        .focused($focusedPIN, equals: .confirmation)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("parent.pin.confirm")
                    Button(controls.isEnabled ? "Change PIN" : "Enable parental controls") {
                        perform {
                            if controls.isEnabled {
                                try controls.changePIN(current: currentPIN, new: newPIN, confirmation: confirmation)
                            } else {
                                try controls.configure(pin: newPIN, confirmation: confirmation)
                            }
                        }
                    }
                    .accessibilityIdentifier("parent.save")
                } header: {
                    Text(controls.isEnabled ? "Change parent PIN" : "Set parent PIN")
                } footer: {
                    Text("Keep this PIN private. Changing or removing restrictions requires it. There is no in-app PIN reset. Controls stay in secure storage when app data is cleared.")
                }
            }
            if let message {
                Section { Text(message).accessibilityIdentifier("parent.message") }
            }
        }
        .navigationTitle("Parental controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { focusedPIN = nil }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Hide keyboard")
                Spacer()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearPINs() }
            else { controls.reload() }
        }
        .onDisappear { clearPINs() }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            message = String(localized: "Parental controls updated.")
            clearPINs()
        } catch {
            message = error.localizedDescription
            currentPIN = ""
        }
    }

    private func clearPINs() {
        focusedPIN = nil
        currentPIN = ""
        newPIN = ""
        confirmation = ""
    }
}
