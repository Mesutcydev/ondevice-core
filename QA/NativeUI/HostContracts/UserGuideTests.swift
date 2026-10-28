import Testing
import UIKit
@testable import NativeUIReview

struct UserGuideTests {
    @Test func bundledTopicsAndVisualsAreComplete() {
        let chapters = UserGuideContent.sections.flatMap(\.chapters)
        #expect(chapters.count == 14)
        #expect(Set(chapters.map(\.id)).count == chapters.count)
        #expect(chapters.reduce(0) { $0 + $1.steps.count } == 61)
        for chapter in chapters {
            #expect(!chapter.steps.isEmpty)
            #expect(Set(chapter.steps.map(\.id)).count == chapter.steps.count)
            for step in chapter.steps {
                switch step.visual {
                case let .screenshot(asset, focus, _):
                    #expect(UIImage(named: asset) != nil, "Missing reference: \(asset)")
                    #expect(focus.x >= 0 && focus.y >= 0 && focus.width > 0 && focus.height > 0)
                    #expect(focus.x + focus.width <= 1 && focus.y + focus.height <= 1)
                case let .flow(nodes, _):
                    #expect(nodes.count == 3)
                    #expect(Set(nodes.map(\.id)).count == nodes.count)
                case .modelStates: break
                }
            }
        }
    }
}
