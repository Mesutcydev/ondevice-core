import Testing
import Foundation
@testable import NativeUIReview

struct ClassifierPrintTests {
    @Test func scoreTicketUsesTheAppsSelectedNumberLocale() {
        let value = result(choice: nil, score: 1.42, yes: nil)
        #expect(ClassifierTicketDecision(value, locale: Locale(identifier: "en")).title == "1.42")
        #expect(ClassifierTicketDecision(value, locale: Locale(identifier: "de")).title == "1,42")
    }
    @Test func falseTicketPrintsConfidenceInFalseRatherThanProbabilityOfTrue() {
        let decision = ClassifierTicketDecision(result(choice: nil, score: nil, yes: 0.12))
        #expect(decision.probability == 0.88)
        #expect(decision.accessibilityIdentifier == "classifier.result.boolean")
        #expect(decision.labelID == nil)
    }

    @Test func scoreTicketUsesTheExpectedIndexRatherThanAProbability() {
        let decision = ClassifierTicketDecision(result(choice: nil, score: 1.42, yes: nil))
        #expect(decision.probability == nil)
        #expect(decision.accessibilityIdentifier == "classifier.result.score")
    }

    @Test func choiceTicketUsesTheChosenLabelsActualProbability() {
        let value = result(choice: "b", score: nil, yes: nil)
        let decision = ClassifierTicketDecision(value)
        #expect(decision.labelID == "b")
        #expect(decision.probability == 0.8)
        #expect(ClassifierTicketRow.ranked(value.answer).map(\.id) == ["b", "a"])
    }

    private func result(choice: String?, score: Double?, yes: Double?) -> ClassifierPrintedResult {
        .init(answer: .init(optionIDs: ["a", "b"], probabilities: [0.2, 0.8], choice: choice,
            score: score, trueProbability: yes, directAnswerProbability: nil, temperature: 1),
            model: .init(id: "fixture", name: "Fixture", window: 512),
            type: score != nil ? .score : yes != nil ? .boolean : .choice, elapsedSeconds: 0.25)
    }
}
