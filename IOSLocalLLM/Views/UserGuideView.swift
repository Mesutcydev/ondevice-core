import SwiftUI
import OnDeviceUI

struct UserGuideView: View {
    var body: some View {
        List {
            Section { UserGuideIntroduction() }
            ForEach(UserGuideContent.sections) { section in
                Section {
                    ForEach(section.chapters) { chapter in
                        NavigationLink {
                            UserGuideChapterView(chapter: chapter)
                        } label: {
                            UserGuideChapterRow(title: chapter.title, summary: chapter.summary, symbol: chapter.symbol)
                        }
                        .accessibilityIdentifier("guide.chapter.\(chapter.id)")
                    }
                } header: { Text(section.title) }
            }
            Section {
                Text("Screen references contain example content. Features depend on your model, device, and app build.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { ODPageBackground().ignoresSafeArea() }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("guide.index")
    }
}

private struct UserGuideIntroduction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Make yourself at home", systemImage: "book.closed").font(.headline)
            Text("Start your first chat, explore each workspace, and learn where your content goes.")
            Text("Local models process content on your device. Downloads and the optional network features you choose can connect to other services.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct UserGuideChapterRow: View {
    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
    }
}

struct UserGuideChapterView: View {
    let chapter: UserGuideChapter
    @State private var stepIndex = 0

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    UserGuideStepInstructions(step: chapter.steps[stepIndex], number: stepIndex + 1, total: chapter.steps.count)
                        .id("guide.step.top")
                    UserGuideStepVisual(visual: chapter.steps[stepIndex].visual, number: stepIndex + 1)
                    UserGuideStepNote(note: chapter.steps[stepIndex].note)
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: stepIndex) { _, _ in scroll.scrollTo("guide.step.top", anchor: .top) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                UserGuideStepNavigation(stepIndex: $stepIndex, total: chapter.steps.count)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Step", selection: $stepIndex) {
                            ForEach(chapter.steps.enumerated(), id: \.element.id) { index, step in
                                Text(step.title).tag(index)
                            }
                        }
                    } label: { Label("Choose a step", systemImage: "list.bullet") }
                    .accessibilityIdentifier("guide.steps")
                }
            }
            .navigationTitle(Text(chapter.title))
            .navigationBarTitleDisplayMode(.inline)
            .background { ODPageBackground().ignoresSafeArea() }
        }
    }
}

private struct UserGuideStepInstructions: View {
    let step: UserGuideStep
    let number: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step \(number) of \(total)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("guide.step.position")
            Text(step.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("guide.step.title")
            Text(step.path).font(.subheadline).foregroundStyle(.secondary)
            Text(step.action).textSelection(.enabled).accessibilityIdentifier("guide.step.action")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct UserGuideStepNote: View {
    let note: LocalizedStringResource
    var body: some View {
        Label { Text(note).font(.subheadline).foregroundStyle(.secondary) } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("guide.step.note")
    }
}

private struct UserGuideStepNavigation: View {
    @Binding var stepIndex: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    let total: Int

    var body: some View {
        HStack(spacing: 16) {
            Button { stepIndex -= 1 } label: {
                UserGuideNavigationLabel(title: "Previous", symbol: "chevron.left",
                                         compact: typeSize.isAccessibilitySize)
            }
                .buttonStyle(.glass).disabled(stepIndex == 0).accessibilityIdentifier("guide.previous")
                .accessibilityLabel("Previous step")
            Spacer(minLength: 0)
            if stepIndex == total - 1 {
                UserGuideNavigationLabel(title: "Topic complete", symbol: "checkmark",
                                         compact: typeSize.isAccessibilitySize)
                    .font(.subheadline).accessibilityIdentifier("guide.complete")
                    .accessibilityLabel("Topic complete")
            } else {
                Button { stepIndex += 1 } label: {
                    UserGuideNavigationLabel(title: "Next", symbol: "chevron.right",
                                             compact: typeSize.isAccessibilitySize)
                }
                    .buttonStyle(.glassProminent).odInkProminent().accessibilityIdentifier("guide.next")
                    .accessibilityLabel("Next step")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(ODPalette.surface)
    }
}

private struct UserGuideNavigationLabel: View {
    let title: LocalizedStringResource
    let symbol: String
    let compact: Bool
    var body: some View {
        Label { Text(title) } icon: { Image(systemName: symbol) }
            .labelStyle(UserGuideAdaptiveLabelStyle(compact: compact))
    }
}

private struct UserGuideAdaptiveLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack { configuration.icon; configuration.title }
        }
    }
}

private struct UserGuideStepVisual: View {
    let visual: UserGuideVisual
    let number: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch visual {
            case let .screenshot(asset, focus, label):
                UserGuideScreenReference(asset: asset, focus: focus, label: label, number: number)
            case let .flow(nodes, code):
                UserGuideFlow(nodes: nodes, code: code)
            case .modelStates:
                UserGuideModelStates()
            }
        }
    }
}

private struct UserGuideScreenReference: View {
    let asset: String
    let focus: UserGuideFocus
    let label: LocalizedStringResource
    let number: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(label) } icon: { Image(systemName: "viewfinder") }.font(.subheadline)
            Image(asset).resizable().scaledToFit()
                .overlay { UserGuideScreenHighlight(focus: focus, number: number) }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: 300).frame(maxWidth: .infinity)
                // The reference image itself is English/LTR in every locale.
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(Text("Example screen. Highlighted: \(Text(label))"))
                .accessibilityIdentifier("guide.screen.\(asset)")
            Text("App capture · example content").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UserGuideScreenHighlight: View {
    let focus: UserGuideFocus
    let number: Int
    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .frame(width: geometry.size.width * CGFloat(focus.width),
                       height: geometry.size.height * CGFloat(focus.height))
                .overlay(alignment: .topLeading) {
                    Text(number, format: .number).font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(6).background(Color.accentColor, in: Circle()).offset(x: -8, y: -10)
                }
                .position(x: geometry.size.width * CGFloat(focus.x + focus.width / 2),
                          y: geometry.size.height * CGFloat(focus.y + focus.height / 2))
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct UserGuideFlow: View {
    let nodes: [UserGuideFlowNode]
    let code: String?
    var body: some View {
        VStack(spacing: 16) {
            ForEach(nodes.enumerated(), id: \.element.id) { index, node in
                VStack(spacing: 16) {
                    if index > 0 {
                        Image(systemName: "arrow.down").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Label { Text(node.title) } icon: { Image(systemName: node.symbol) }
                        .multilineTextAlignment(.center)
                }
            }
            if let code { Text(code).font(.footnote.monospaced()).textSelection(.enabled) }
        }
        .padding(.vertical, 16).frame(maxWidth: .infinity)
        .accessibilityIdentifier("guide.diagram")
    }
}

private struct UserGuideModelStates: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            UserGuideStateRow(title: "Available", detail: "Catalog entry; files not downloaded", symbol: "cloud")
            UserGuideStateRow(title: "Downloading", detail: "Files transfer to your device", symbol: "arrow.down.circle")
            UserGuideStateRow(title: "Preparing", detail: "Local conversion when the format needs it", symbol: "gearshape.2")
            UserGuideStateRow(title: "Installed", detail: "Files available on disk", symbol: "internaldrive")
            UserGuideStateRow(title: "Loaded", detail: "Active in runtime memory", symbol: "cpu")
        }
        .accessibilityIdentifier("guide.modelStates")
    }
}

private struct UserGuideStateRow: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let symbol: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
    }
}
