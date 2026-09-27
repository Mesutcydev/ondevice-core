import Foundation
import SwiftUI

// MARK: - Persona
// A bundled-up system prompt + display metadata. The user picks one before
// (or during) a chat to flavor how the assistant behaves.

struct Persona: Identifiable, Codable, Hashable {
    var id: String              // stable key
    var name: String            // display name
    var subtitle: String        // short description
    var systemPrompt: String    // the actual instructions injected
    var icon: String            // SF Symbol
    var accentName: String      // "accent" / "good" / "warn" / "bad"
    var isBuiltIn: Bool         // true for presets, false for user-created

    var accent: Color {
        switch accentName {
        case "good": return .green
        case "warn": return .orange
        case "bad":  return .red
        default:     return .blue
        }
    }
}

// MARK: - PersonaStore
// In-memory + UserDefaults-backed catalog. Built-ins are always present;
// user-created personas append to the end.

@MainActor
final class PersonaStore: ObservableObject {

    static let shared = PersonaStore()

    @Published private(set) var personas: [Persona] = []
    @Published var activeID: String {
        didSet { UserDefaults.standard.set(activeID, forKey: Self.activeKey) }
    }

    private static let userPersonasKey = "userPersonas.v1"
    private static let activeKey = "activePersonaID"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.activeKey)
        self.activeID = stored.map { Self.retiredIDs[$0] ?? $0 } ?? "general"
        var all = Self.builtIns
        if let data = UserDefaults.standard.data(forKey: Self.userPersonasKey),
           let custom = try? JSONDecoder().decode([Persona].self, from: data) {
            all.append(contentsOf: custom)
        }
        self.personas = all
    }

    // MARK: - Built-in presets

    // Eight current presets for a private, on-device workspace. Each prompt is
    // short on purpose: it sits in every reply's context, and some models run
    // with a 2K-token window. The shared rules (grounding, formatting, date,
    // language, tools) come from the prompt builder, not from here.
    static let builtIns: [Persona] = [
        Persona(
            id: "general",
            name: "Assistant",
            subtitle: "Everyday questions and tasks",
            systemPrompt: """
            You are a capable everyday assistant for questions, writing, \
            planning and quick tasks. Ask one short question only when a \
            request is truly ambiguous.
            """,
            icon: "sparkles",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "writer",
            name: "Writer",
            subtitle: "Drafts, edits, tone and stories",
            systemPrompt: """
            You are a skilled writer and editor. When editing, keep the \
            author's meaning and voice: return the improved text first, then \
            at most three short notes on what changed. When drafting, match \
            the requested tone and length. For stories and poems, be vivid \
            and original.
            """,
            icon: "pencil.line",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "coder",
            name: "Coder",
            subtitle: "Write, review and debug code",
            systemPrompt: """
            You are a senior software engineer and pair programmer. Give \
            working code in fenced blocks with a language tag, then a brief \
            explanation. When reviewing, list bugs and security issues first, \
            most severe first, citing the line. Prefer small, safe changes, \
            and never invent APIs, files or errors you have not seen.
            """,
            icon: "chevron.left.forwardslash.chevron.right",
            accentName: "good",
            isBuiltIn: true
        ),
        Persona(
            id: "translator",
            name: "Translator",
            subtitle: "Natural translation between languages",
            systemPrompt: """
            You are a professional translator. Translate faithfully and \
            idiomatically, keeping formatting, names and numbers. If no target \
            language is given, translate into English, or into the user's \
            device language when the text is already English. Reply with only \
            the translation unless asked for notes.
            """,
            icon: "character.bubble",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "tutor",
            name: "Tutor",
            subtitle: "Step-by-step explanations",
            systemPrompt: """
            You are a patient tutor. Explain step by step with a small \
            example, and name the idea behind each step. For homework, guide \
            the learner toward the answer rather than only stating it. End \
            with one short question that checks understanding.
            """,
            icon: "graduationcap",
            accentName: "good",
            isBuiltIn: true
        ),
        Persona(
            id: "analyst",
            name: "Analyst",
            subtitle: "Summaries of files, pages and notes",
            systemPrompt: """
            You are a careful analyst. Summarize, compare and extract from \
            the material the user provides: files, web results or pasted \
            text. Lead with the key points as bullets, then supporting detail \
            with its source. Keep facts separate from your interpretation, and \
            list action items when there are any.
            """,
            icon: "doc.text.magnifyingglass",
            accentName: "warn",
            isBuiltIn: true
        ),
        Persona(
            id: "planner",
            name: "Planner",
            subtitle: "Plans, routines and goals",
            systemPrompt: """
            You are a practical planner and coach. Turn goals into ordered, \
            concrete steps with rough time estimates, fitted to the user's \
            constraints. Flag what to do first, and end with one small next \
            action the user can take today.
            """,
            icon: "checklist",
            accentName: "good",
            isBuiltIn: true
        ),
        Persona(
            id: "brainstorm",
            name: "Brainstormer",
            subtitle: "Ideas, names and options",
            systemPrompt: """
            You are a creative brainstorming partner. Offer several distinct \
            ideas as a numbered list, each with a one-line reason. Mix safe and \
            bold options, build on the user's own ideas, and ask which \
            direction to develop.
            """,
            icon: "bubbles.and.sparkles",
            accentName: "warn",
            isBuiltIn: true
        ),
    ]

    /// Presets retired in the September 2026 refresh, mapped to their
    /// successor so a saved choice keeps working.
    static let retiredIDs: [String: String] = [
        "default": "coder", "code-reviewer": "coder", "sql-expert": "coder",
        "security": "coder", "refactor": "coder", "explain": "coder",
        "storyteller": "writer", "researcher": "analyst", "coach": "planner",
    ]

    // MARK: - Public API

    var active: Persona {
        personas.first(where: { $0.id == activeID }) ?? Self.builtIns[0]
    }

    func setActive(_ id: String) {
        activeID = id
    }

    func add(_ persona: Persona) {
        personas.append(persona)
        persistUserPersonas()
    }

    func update(_ persona: Persona) {
        if let idx = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[idx] = persona
            persistUserPersonas()
        }
    }

    func delete(_ id: String) {
        guard let p = personas.first(where: { $0.id == id }), !p.isBuiltIn else { return }
        personas.removeAll { $0.id == id }
        if activeID == id { activeID = "general" }
        persistUserPersonas()
    }

    func resetForWipe() {
        UserDefaults.standard.removeObject(forKey: Self.userPersonasKey)
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
        activeID = "general"
        personas = Self.builtIns
    }

    private func persistUserPersonas() {
        let custom = personas.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.userPersonasKey)
        }
    }
}
