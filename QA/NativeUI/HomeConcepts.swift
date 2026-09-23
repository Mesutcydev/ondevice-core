import SwiftUI
import OnDeviceUI

/// Review-only alternatives. No production screen or runtime is replaced.
struct HomeConceptReview: View {
    let variant: String
    @State private var text = ""
    @State private var note: String?
    @FocusState private var focus: Bool
    @EnvironmentObject private var store: ODStore

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch variant {
                    case "tools": ToolsHomeConcept(onChoose: choose)
                    case "library": LibraryHomeConcept(onChoose: choose)
                    default: FocusHomeConcept(onChoose: choose)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home.concept")
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("OnDevice").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("App menu", systemImage: "line.3.horizontal") { store.conversationsPresented = true }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New conversation") { text = ""; focus = true }
                        Button("Settings") { store.secondaryRoute = .settings }
                    } label: { Image(systemName: "ellipsis") }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    ODKeyboardDismissKey(focus: $focus)
                    Spacer(minLength: 0)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODComposer(text: $text, focus: $focus, attachments: [], isResponding: false,
                    canSend: !text.isEmpty, canStop: false, canAdd: true, canRemove: false,
                    modelMenu: AnyView(Menu { Button("Models") { store.selectedTab = .models } } label: {
                        HStack(spacing: 6) { Text("Ornith 1.5 9B").font(.subheadline.weight(.semibold)).foregroundStyle(ODPalette.text); Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(ODPalette.secondary) }
                    }),
                    microphone: AnyView(Button("Microphone", systemImage: "mic") { choose("Voice preview") }
                        .labelStyle(.iconOnly).buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)),
                    onAdd: { choose("Attach a file") }, onRemove: { _ in },
                    onSend: { _, _ in choose("Conversation preview") }, onStop: {})
            }
            .alert("Design preview", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
                Button("OK") { note = nil }
            } message: { Text(note ?? "") }
        }
    }
    private func choose(_ action: String) {
        switch action {
        case "Write": focus = true
        case "Images": store.secondaryRoute = .imageStudio
        case "History": store.conversationsPresented = true
        default: note = action
        }
    }
}

private struct FocusHomeConcept: View {
    let onChoose: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 7) {
                Image(systemName: "iphone").font(.caption)
                Text("On this iPhone").font(.footnote)
                Spacer()
                Text("Private by default").font(.caption)
            }.foregroundStyle(ODPalette.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Text("A fresh\nconversation.")
                    .font(.system(size: 36, weight: .semibold)).tracking(-1.2)
                    .lineSpacing(-2)
                HStack {
                    Text("Where shall we start?")
                        .font(.body).foregroundStyle(ODPalette.secondary)
                    Spacer()
                    Button { onChoose("Write") } label: {
                        Image(systemName: "arrow.up.right").font(.title3)
                            .frame(width: 48, height: 48)
                            .background(ODPalette.text, in: Circle())
                            .foregroundStyle(ODPalette.background)
                    }.buttonStyle(.plain).accessibilityLabel("Start writing")
                }
                Divider().overlay(ODPalette.line)
                VStack(spacing: 0) {
                    FocusStarter(title: "Untangle an idea", symbol: "bubble.left.and.text.bubble.right") { onChoose("Write") }
                    FocusStarter(title: "Bring a document", symbol: "doc.text") { onChoose("Attach a file") }
                    FocusStarter(title: "Make an image", symbol: "photo") { onChoose("Images") }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ODPalette.surface, in: RoundedRectangle(cornerRadius: 28))
            .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(ODPalette.line, lineWidth: 0.7) }
            Button { onChoose("History") } label: {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(ODPalette.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Pick up where you left off").font(.footnote).foregroundStyle(ODPalette.secondary)
                        Text("Plan a focused workday").font(.body.weight(.medium))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.footnote)
                }
                .padding(.horizontal, 4).padding(.vertical, 12)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .foregroundStyle(ODPalette.text)
    }
}

private struct FocusStarter: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body).frame(width: 24).foregroundStyle(ODPalette.secondary)
                Text(title).font(.body)
                Spacer(minLength: 0)
                Image(systemName: "plus").font(.footnote).foregroundStyle(ODPalette.secondary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ToolsHomeConcept: View {
    let onChoose: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Make it happen.").font(.system(size: 32, weight: .semibold)).tracking(-1)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [.init(.flexible(), spacing: 12), .init(.flexible(), spacing: 12)], spacing: 12) {
                ConceptToolTile(title: "Write", detail: "Find the right words", kind: "write", bright: true) { onChoose("Write") }
                ConceptToolTile(title: "Documents", detail: "Read. Ask. Understand.", kind: "documents") { onChoose("Attach a file") }
                ConceptToolTile(title: "Images", detail: "From thought to image", kind: "images") { onChoose("Images") }
                ConceptToolTile(title: "Code", detail: "Build. Fix. Learn.", kind: "code") { onChoose("Code workspace") }
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Continue").font(.subheadline.weight(.medium)).foregroundStyle(ODPalette.secondary)
                    Spacer()
                    Button("View all") { onChoose("History") }.font(.subheadline)
                }.frame(minHeight: 32)
                Button { onChoose("History") } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left").foregroundStyle(ODPalette.secondary)
                        Text("Plan a focused workday").font(.body)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left").font(.footnote).foregroundStyle(ODPalette.secondary)
                    }.frame(minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.foregroundStyle(ODPalette.text)
    }
}

private struct ConceptToolTile: View {
    let title: String
    let detail: String
    let kind: String
    var bright = false
    let action: () -> Void
    private var ink: Color { bright ? ODPalette.background : ODPalette.text }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Group {
                        switch kind {
                        case "write": Text("Aa").font(.system(size: 37, weight: .regular, design: .serif))
                        case "documents": Image(systemName: "doc.on.doc").font(.system(size: 29, weight: .light)).padding(.top, 5)
                        case "images": Image(systemName: "square.stack.3d.up").font(.system(size: 31, weight: .light)).padding(.top, 4)
                        default: Text("{ }").font(.system(size: 33, weight: .light, design: .monospaced))
                        }
                    }.frame(height: 47)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).opacity(0.55).padding(.top, 5)
                }
                Spacer(minLength: 20)
                Text(title).font(.title3.weight(.medium))
                Text(detail).font(.caption).opacity(0.6).padding(.top, 5).lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .background(bright ? ODPalette.text : ODPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(bright ? .clear : ODPalette.line, lineWidth: 0.7) }
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }
}

private struct LibraryHomeConcept: View {
    let onChoose: (String) -> Void
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your conversations")
                        .font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                    Text("A place for everything you’re thinking.")
                        .font(.footnote).foregroundStyle(ODPalette.secondary)
                }
                Spacer(minLength: 4)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(ODPalette.secondary)
                TextField("Find a conversation", text: $search).font(.subheadline)
            }.padding(14).background(ODPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            if search.isEmpty || "Plan a focused workday".localizedCaseInsensitiveContains(search) {
                Button { onChoose("History") } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Last opened", systemImage: "clock").font(.caption).foregroundStyle(ODPalette.secondary)
                            Spacer()
                            Text("Today").font(.caption).foregroundStyle(ODPalette.secondary)
                        }
                        Text("Plan a focused workday").font(.system(size: 24, weight: .medium)).tracking(-0.5)
                        Text("Start with one important task. Give it your first uninterrupted hour.")
                            .font(.subheadline).foregroundStyle(ODPalette.secondary).lineLimit(2)
                        HStack {
                            Text("Continue conversation").font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "arrow.right")
                        }.padding(.top, 4)
                    }
                    .padding(22)
                    .background(ODPalette.surface, in: RoundedRectangle(cornerRadius: 24))
                    .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(ODPalette.line, lineWidth: 0.7) }
                }.buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Earlier").font(.footnote).foregroundStyle(ODPalette.secondary)
                    Spacer()
                    Button("All conversations") { onChoose("History") }.font(.footnote)
                }.padding(.bottom, 8)
                if search.isEmpty || "Notes from this week".localizedCaseInsensitiveContains(search) {
                    LibraryThreadRow(title: "Notes from this week", detail: "Yesterday", symbol: "doc.text") { onChoose("History") }
                }
                if search.isEmpty || "A small Swift fix".localizedCaseInsensitiveContains(search) {
                    Divider()
                    LibraryThreadRow(title: "A small Swift fix", detail: "Thursday", symbol: "chevron.left.forwardslash.chevron.right") { onChoose("History") }
                }
            }
        }.foregroundStyle(ODPalette.text)
    }
}

private struct LibraryThreadRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body).foregroundStyle(ODPalette.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(ODPalette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(ODPalette.secondary)
            }.padding(.vertical, 13).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
