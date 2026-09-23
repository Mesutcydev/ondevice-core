import SwiftUI
import OnDeviceUI

struct AnalysisHistoryView: View {
    @ObservedObject var analysis: AnalysisService
    @Binding var openPanel: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(analysis.analysisResults) { result in
                    Button { open(result) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            if let thumbnail = result.thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFill()
                                    .frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 12))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.detection.label).font(.headline)
                                Text(result.extractedCode).font(.body).lineLimit(3)
                                Text(result.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.right.square") { open(result) }
                        Button("Copy text", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = result.extractedCode
                            ToastCenter.shared.info("Copied to clipboard")
                        }
                        Button("Ask in Chat", systemImage: "bubble.left") {
                            AppBridge.shared.sendToAssistant(code: result.extractedCode,
                                source: result.mode == .visual ? "FastVLM Vision" : "FastVLM")
                            dismiss()
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { analysis.deleteResult(result.id) }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { analysis.deleteResult(result.id) }
                    }
                }
            }
            .overlay {
                if analysis.analysisResults.isEmpty {
                    ContentUnavailableView("No captures yet", systemImage: "photo.stack",
                        description: Text("Capture or import an image to start your history. Recent results stay here for this session."))
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Capture history").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !analysis.analysisResults.isEmpty {
                        Button("Clear history", systemImage: "trash", role: .destructive) { showClearConfirm = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear all results?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { analysis.clearHistory() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func open(_ result: AnalysisResult) {
        analysis.reopen(result)
        openPanel = true
        dismiss()
    }
}

// MARK: - AnalysisHistoryCard

struct AnalysisHistoryCard: View {
    let result: AnalysisResult
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let thumb = result.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 110)
                        .clipped()
                } else {
                    ZStack {
                        T.surface2
                        Image(systemName: "photo")
                            .foregroundColor(T.ink3)
                    }
                    .frame(height: 110)
                }

                modeBadge
                    .padding(6)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(T.rule).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                KMono(text: result.detection.label, size: 10, weight: .medium, color: T.ink)
                    .lineLimit(1)
                Text(snippet)
                    .font(T.sans(11))
                    .foregroundColor(T.ink2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    KMono(text: result.timestamp.formatted(date: .omitted, time: .shortened),
                           size: 9, color: T.ink3)
                    Spacer()
                    if !result.questionAnswers.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 9))
                            Text("\(result.questionAnswers.count)")
                                .font(T.mono(9))
                        }
                        .foregroundColor(T.accent)
                    }
                }
            }
            .padding(10)
        }
        .kGlass(cornerRadius: StudioRadius.tile, fallbackFill: T.surface)
    }

    private var snippet: String {
        let raw = result.extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return result.fallbackReason ?? "—"
        }
        return raw
    }

    private var modeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: result.mode.systemImage)
                .font(.system(size: 8, weight: .bold))
            Text(result.mode.displayName.lowercased())
                .font(T.mono(9, .semibold))
                .tracking(0.4)
        }
        .foregroundColor(result.mode == .visual ? T.accent : T.good)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: StudioRadius.panel)
            .fill((result.mode == .visual ? T.accent : T.good).opacity(0.15)))
    }
}
