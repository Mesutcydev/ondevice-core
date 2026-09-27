import SwiftUI

@MainActor
struct ODVoiceLibraryView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var language: String?
    @State private var source: VoiceSource = .all
    @ScaledMetric(relativeTo: .body) private var previewIconSide: CGFloat = ODLayout.standardIcon

    private var filteredVoices: [ODVoice] {
        store.voices.filter { voice in
            let matchesFilter = (language == nil || voice.language == language)
                && (source == .all || (source == .cloned ? voice.isCloned : !voice.isCloned))
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesFilter && (query.isEmpty ||
                "\(voice.name) \(voice.language) \(voice.locale)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !searchFocused && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        selectedVoiceSummary
                            .listRowInsets(EdgeInsets(top: 8, leading: ODLayout.pageInset, bottom: 8, trailing: ODLayout.pageInset))
                            .listRowSeparator(.hidden)
                    }
                }
                .listRowBackground(Color.clear)

                Section {
                    if filteredVoices.isEmpty {
                        ContentUnavailableView {
                            Label(store.voices.isEmpty ? "No voices yet" : "No matching voices", systemImage: "waveform")
                        } description: {
                            Text(store.voices.isEmpty ? "Your available voices will appear here." : "Try another name, language, or filter.")
                        }
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredVoices) { voice in
                            voiceRow(voice)
                                .listRowInsets(EdgeInsets(top: 8, leading: ODLayout.pageInset, bottom: 8, trailing: ODLayout.pageInset))
                        }
                    }
                } header: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text("Voices · \(filteredVoices.count)").font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            filters
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Voices · \(filteredVoices.count)").font(.subheadline.weight(.semibold))
                            filters
                        }
                    }
                    .textCase(nil).foregroundStyle(.primary)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search voices")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { searchFocused = false }
            .onChange(of: store.conversationsPresented) { _, open in
                if open { searchFocused = false }
            }
            .onChange(of: store.selectedTab) { _, destination in
                if destination != .voice { searchFocused = false }
            }
            .navigationTitle("Voices")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar {
                    if !searchFocused && !store.voiceSessionActive { conversationAction }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton {
                        store.conversationsPresented = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("navigation.menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Voice options", systemImage: "slider.horizontal.3") {
                        Section {
                            Button { store.send(.selectEngine) } label: {
                                Label("Speech engine", systemImage: "waveform")
                                Text(store.voiceEngineName)
                            }
                            .disabled(!store.capabilities.canSelectEngine)
                        }
                        Section {
                            Button("Settings", systemImage: "gearshape") { store.secondaryRoute = .settings }
                        }
                    }
                    .menuOrder(.fixed)
                    .labelStyle(.iconOnly)
                }
            }
        }
        .tint(ODPalette.text)
        .onChange(of: store.selectedTab) { _, tab in
            if tab != .voice { stopPreviewIfNeeded() }
        }
        .onChange(of: store.voiceSessionPresented) { _, isPresented in
            if isPresented { stopPreviewIfNeeded() }
        }
        .onDisappear { stopPreviewIfNeeded() }
    }

    private var selectedVoiceSummary: some View {
        HStack(alignment: .center, spacing: 4 * ODLayout.unit) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaking as")
                    .font(.caption)
                    .foregroundStyle(ODPalette.secondary)
                if let voice = store.selectedVoice {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(voice.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize()
                            .accessibilityIdentifier("voice.current.name")
                        Text("\(voice.language) · \(voice.locale)")
                            .font(.caption)
                            .foregroundStyle(ODPalette.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    Text("Choose a voice below")
                        .font(.subheadline)
                        .foregroundStyle(ODPalette.secondary)
                        .accessibilityIdentifier("voice.current.name")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let voice = store.selectedVoice {
                previewButton(for: voice, showsTitle: false)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ODLayout.labelGap) { languagePicker; sourcePicker }
            VStack(alignment: .leading, spacing: ODLayout.elementGap) { languagePicker; sourcePicker }
        }
    }

    private var languagePicker: some View {
        Picker("Language", selection: $language) {
            Text("All languages").tag(String?.none)
            ForEach(Array(Set(store.voices.map(\.language))).sorted(), id: \.self) { name in
                Text(name).tag(Optional(name))
            }
        }
        .pickerStyle(.menu).labelsHidden().frame(minHeight: ODLayout.minimumHit)
        .accessibilityIdentifier("voice.language")
    }

    @ViewBuilder private var sourcePicker: some View {
        if store.voices.contains(where: \.isCloned) {
            Picker("Voice source", selection: $source) {
                ForEach(VoiceSource.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .pickerStyle(.menu).frame(minHeight: ODLayout.minimumHit)
            .accessibilityIdentifier("voice.source")
        }
    }

    private func voiceRow(_ voice: ODVoice) -> some View {
        let selected = store.selectedVoiceID == voice.id
        return HStack(spacing: ODLayout.labelGap) {
            Button {
                store.send(.selectVoice(voice.id))
            } label: {
                HStack(spacing: ODLayout.labelGap) {
                    VStack(alignment: .leading, spacing: ODLayout.unit) {
                        Text(voice.name)
                            .font(.body.weight(selected ? .semibold : .regular))
                            .foregroundStyle(ODPalette.text)
                        Text("\(voice.language) · \(voice.locale)")
                            .font(.subheadline)
                            .foregroundStyle(ODPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if voice.isCloned {
                            Text("Cloned voice")
                                .font(.caption)
                                .foregroundStyle(ODPalette.secondary)
                        } else if voice.isMultilingual {
                            Text("Multilingual")
                                .font(.caption)
                                .foregroundStyle(ODPalette.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ODPalette.text)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 13 * ODLayout.unit, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canPerformActions)
            .accessibilityLabel("\(voice.name), \(voice.language), \(voice.locale)")
            .accessibilityHint("Select this voice")
            .accessibilityAddTraits(selected ? .isSelected : [])

            previewButton(for: voice, showsTitle: false)
        }
    }

    private func previewButton(for voice: ODVoice, showsTitle: Bool) -> some View {
        let playing = store.voicePreviewID == voice.id
        let enabled = store.canPerformActions &&
            ((store.capabilities.canPreviewVoices && !store.voiceSessionActive) || playing)
        return VStack(spacing: ODLayout.unit) {
            Button {
                store.send(playing ? .stopVoicePreview : .previewVoice(voice.id))
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.body.weight(.medium))
                    .frame(width: previewIconSide, height: previewIconSide)
                    .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(playing ? "Stop \(voice.name) preview" : "Preview \(voice.name)")
            .accessibilityValue(playing ? "Playing" : "Stopped")
            .accessibilityHint("Plays a sample without starting a conversation")
            if showsTitle {
                Text(playing ? "Stop" : "Preview")
                    .font(.caption)
                    .foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    private var conversationAction: some View {
        VStack(alignment: .leading, spacing: ODLayout.labelGap) {
            if store.voiceSessionActive {
                ODPrimaryButton("Return to conversation", symbol: "waveform") {
                    stopPreviewIfNeeded()
                    store.voiceSessionPresented = true
                }
            } else {
                if let message = store.voiceAvailabilityMessage, !message.isEmpty {
                    Button("Voice setup", systemImage: "slider.horizontal.3") { store.send(.selectEngine) }
                        .frame(minHeight: ODLayout.minimumHit)
                        .disabled(!store.capabilities.canSelectEngine)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ODPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.selectedVoice == nil {
                    Text("Choose a voice to begin.")
                        .font(.footnote)
                        .foregroundStyle(ODPalette.secondary)
                } else if !store.capabilities.canStartVoice || !store.canPerformActions {
                    Text("Voice conversation is unavailable.")
                        .font(.footnote)
                        .foregroundStyle(ODPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ODPrimaryButton("Start conversation", symbol: "waveform") {
                    stopPreviewIfNeeded()
                    store.send(.beginVoiceSession)
                }
                .disabled(!store.canPerformActions || !store.capabilities.canStartVoice || store.selectedVoice == nil)
            }
        }
        .padding(.horizontal, ODLayout.gutter)
        .padding(.vertical, ODLayout.labelGap)
        .background { ODPageBackground().ignoresSafeArea() }
    }

    private func stopPreviewIfNeeded() {
        if store.voicePreviewID != nil {
            store.send(.stopVoicePreview)
        }
    }

    private enum VoiceSource: String, CaseIterable, Identifiable {
        case all = "All sources", catalog = "Catalog voices", cloned = "Cloned voices"
        var id: String { rawValue }
    }
}
