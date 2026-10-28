// Adapted from the owner-supplied Token AI Classifier, App/Design/Ticket.swift.
// Paper, typography, count-up and row timing match the original classifier.
import SwiftUI
import UIKit
import OnDeviceUI

enum ClassifierPrintStyle {
    static let signalFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.788, green: 0.278, blue: 0.118, alpha: 1)
            : UIColor(red: 0.769, green: 0.267, blue: 0.110, alpha: 1)
    })
    static let paper = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.902, green: 0.847, blue: 0.753, alpha: 1)
            : UIColor(red: 0.965, green: 0.922, blue: 0.851, alpha: 1)
    })
    static let ink = Color(red: 0.141, green: 0.106, blue: 0.082)
    static let receipt = Font.system(.footnote, design: .monospaced)
    static let caption = Font.system(.caption2, design: .monospaced, weight: .semibold)

    static func labelColor(_ id: String) -> Color {
        let colors: [Color] = [
            .init(red: 0.831, green: 0.337, blue: 0.165), .init(red: 0.788, green: 0.604, blue: 0.180),
            .init(red: 0.431, green: 0.624, blue: 0.420), .init(red: 0.235, green: 0.604, blue: 0.604),
            .init(red: 0.357, green: 0.498, blue: 0.749), .init(red: 0.604, green: 0.373, blue: 0.659),
            .init(red: 0.788, green: 0.376, blue: 0.478), .init(red: 0.557, green: 0.561, blue: 0.235)
        ]
        let hash = id.unicodeScalars.reduce(UInt32(5381)) { $0 &* 33 &+ $1.value }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

struct ClassifierTicketDecision {
    let title: String
    let caption: LocalizedStringResource
    let color: Color
    let probability: Double?
    let labelID: String?
    let accessibilityIdentifier: String

    init(_ result: ClassifierPrintedResult, locale: Locale = .current) {
        let answer = result.answer
        if let selected = answer.choice {
            title = selected; labelID = selected
            caption = "Top category"
            color = ClassifierPrintStyle.labelColor(selected)
            probability = answer.optionIDs.firstIndex(of: selected).flatMap { index in
                answer.probabilities.indices.contains(index) ? answer.probabilities[index] : nil
            }
            accessibilityIdentifier = "classifier.result.choice"
        } else if let score = answer.score {
            title = score.formatted(.number.precision(.fractionLength(2)).locale(locale))
            caption = "Expected rubric index"
            color = ClassifierPrintStyle.signalFill
            probability = nil; labelID = nil
            accessibilityIdentifier = "classifier.result.score"
        } else if let yes = answer.trueProbability {
            title = yes >= 0.5 ? "True" : "False"
            caption = "Yes / no decision"
            color = ClassifierPrintStyle.signalFill
            // The printed confidence belongs to the answer on the ticket.
            probability = yes >= 0.5 ? yes : 1 - yes
            labelID = nil
            accessibilityIdentifier = "classifier.result.boolean"
        } else {
            title = "No decision"
            caption = "No decision returned"
            color = ClassifierPrintStyle.ink.opacity(0.4)
            probability = nil; labelID = nil
            accessibilityIdentifier = "classifier.result.empty"
        }
    }
}

struct ClassifierTicketRow: Identifiable {
    let id: String
    let probability: Double

    static func ranked(_ answer: CoreAIClassifierAnswer) -> [Self] {
        zip(answer.optionIDs, answer.probabilities).map { Self(id: $0.0, probability: $0.1) }
            .sorted { $0.probability == $1.probability ? $0.id < $1.id : $0.probability > $1.probability }
    }
}

struct ClassifierResultTicket: View {
    let result: ClassifierPrintedResult
    var isStale = false
    var animated = true
    @State private var printed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

    private var decision: ClassifierTicketDecision { .init(result, locale: locale) }
    private var runnersUp: [ClassifierTicketRow] {
        ClassifierTicketRow.ranked(result.answer).filter { $0.id != decision.labelID }
    }
    private var showAll: Bool { printed || !animated || reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ClassifierTriangle().fill(decision.color).frame(width: 11, height: 11)
                Text(decision.caption)
                    .font(ClassifierPrintStyle.caption).tracking(0.6)
                    .foregroundStyle(ClassifierPrintStyle.ink.opacity(0.55)).lineLimit(2)
            }
            ClassifierTicketTitle(title: decision.title, isCategoryOrScore: result.answer.choice != nil || result.answer.score != nil)
                .font(.system(.title2, weight: .heavy).width(.expanded))
                .tracking(-0.4).minimumScaleFactor(0.55).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            if let probability = decision.probability {
                ClassifierTicketFigure(probability: probability, showAll: showAll).padding(.top, 6)
            }
            if !runnersUp.isEmpty {
                ClassifierPerforatedRule().padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(runnersUp.prefix(4).enumerated()), id: \.element.id) { index, row in
                        ClassifierReceiptLine(name: row.id, probability: row.probability)
                            .opacity(showAll ? 1 : 0).offset(y: showAll ? 0 : -4)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.25)
                                .delay(0.45 + Double(index) * 0.07), value: printed)
                    }
                    if runnersUp.count > 4 {
                        Text("+ \(runnersUp.count - 4) more")
                            .font(ClassifierPrintStyle.caption)
                            .foregroundStyle(ClassifierPrintStyle.ink.opacity(0.5))
                    }
                }
            }
            ClassifierPerforatedRule().padding(.top, 12).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.model.name).lineLimit(1)
                Text("\(result.elapsedSeconds, format: .number.precision(.fractionLength(2))) s · On device")
            }
            .font(ClassifierPrintStyle.caption).foregroundStyle(ClassifierPrintStyle.ink.opacity(0.5))
        }
        .foregroundStyle(ClassifierPrintStyle.ink)
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ClassifierTornPaper()
                .fill(ClassifierPrintStyle.paper)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
                .clipShape(ClassifierTornPaper())
                .shadow(color: .black.opacity(0.22), radius: 10, y: 8)
        }
        .overlay(alignment: .bottomTrailing) {
            if isStale { ClassifierStaleStamp().padding(.bottom, 22).padding(.trailing, 12) }
        }
        .saturation(isStale ? 0 : 1).opacity(isStale ? 0.7 : 1)
        .task(id: workspaceVisible && scenePhase == .active) {
            guard workspaceVisible, scenePhase == .active, animated, !reduceMotion, !printed else { return }
            withAnimation(.smooth(duration: 0.8).delay(0.3)) { printed = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(decision.accessibilityIdentifier)
        .accessibilityHint(isStale ? Text("This result belongs to the previous input.") : Text("Shows all scores and execution details"))
    }
}

private struct ClassifierTicketTitle: View {
    let title: String
    let isCategoryOrScore: Bool
    var body: some View {
        if isCategoryOrScore { Text(title) }
        else { Text(odKey: title) }
    }
}

private struct ClassifierTicketFigure: View {
    let probability: Double
    let showAll: Bool

    var body: some View {
        let value = showAll ? probability : 0
        VStack(alignment: .leading, spacing: 8) {
            Text(value, format: .percent.precision(.fractionLength(0...1)))
                .font(.system(.title, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: value))
            GeometryReader { proxy in
                Capsule().fill(ClassifierPrintStyle.ink.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(ClassifierPrintStyle.signalFill)
                            .frame(width: proxy.size.width * (showAll ? min(max(probability, 0), 1) : 0))
                    }
            }
            .frame(height: 4).accessibilityHidden(true)
        }
    }
}

private struct ClassifierReceiptLine: View {
    let name: String
    let probability: Double
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            ClassifierReceiptLeader()
            Text(probability, format: .percent.precision(.fractionLength(0...1)))
                .monospacedDigit().layoutPriority(2)
        }
        .font(ClassifierPrintStyle.receipt)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(probability, format: .percent.precision(.fractionLength(1)))")
    }
}

/// Drawing the same dotted leader inside its bounds keeps clipped text from
/// extending the ticket's accessibility frame beyond the visible paper.
private struct ClassifierReceiptLeader: View {
    @ScaledMetric(relativeTo: .footnote) private var spacing: CGFloat = 7.8
    @ScaledMetric(relativeTo: .footnote) private var dot: CGFloat = 1.2
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 8
    var body: some View {
        Canvas { context, size in
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                let rect = CGRect(x: x - dot / 2, y: (size.height - dot) / 2, width: dot, height: dot)
                context.fill(Path(ellipseIn: rect), with: .color(ClassifierPrintStyle.ink.opacity(0.25)))
            }
        }
        .frame(minWidth: 8, maxWidth: .infinity).frame(height: height)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        .accessibilityHidden(true)
    }
}

private struct ClassifierPerforatedRule: View {
    var body: some View {
        ClassifierReceiptRule()
            .stroke(ClassifierPrintStyle.ink.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1).accessibilityHidden(true)
    }
}

private struct ClassifierReceiptRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

private struct ClassifierStaleStamp: View {
    var body: some View {
        Text("PREVIOUS\nINPUT")
            .font(.system(.caption2, design: .monospaced, weight: .heavy))
            .multilineTextAlignment(.center).foregroundStyle(ClassifierPrintStyle.ink.opacity(0.7))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(ClassifierPrintStyle.ink.opacity(0.7), lineWidth: 1.5) }
            .rotationEffect(.degrees(-9)).accessibilityHidden(true)
    }
}

struct ClassifierTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            .init(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        return Path { path in
            path.move(to: point(0.66, 0.08))
            path.addQuadCurve(to: point(0.77, 0.12), control: point(0.74, 0.01))
            path.addLine(to: point(0.97, 0.83))
            path.addQuadCurve(to: point(0.88, 0.95), control: point(1.01, 0.96))
            path.addLine(to: point(0.09, 0.78))
            path.addQuadCurve(to: point(0.06, 0.66), control: point(-0.02, 0.76))
            path.closeSubpath()
        }
    }
}

private struct ClassifierTornPaper: Shape {
    func path(in rect: CGRect) -> Path {
        let count = max(Int((rect.width / 10).rounded()), 1)
        let step = rect.width / CGFloat(count)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 4))
            for index in 0..<count {
                let x = rect.maxX - CGFloat(index) * step
                path.addLine(to: CGPoint(x: x - step / 2, y: rect.maxY))
                path.addLine(to: CGPoint(x: x - step, y: rect.maxY - 4))
            }
            path.closeSubpath()
        }
    }
}
