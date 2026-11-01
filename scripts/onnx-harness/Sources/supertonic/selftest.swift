import Foundation
func selftest() {
    let a = SupertonicPipeline.preprocess("Hello — world", lang: "en")
    let b = SupertonicPipeline.preprocess("Merhaba 😀 dünya!", lang: "tr")
    print("A", a, a == "<en>Hello - world.</en>")
    print("B", b, b == "<tr>Merhaba dünya!</tr>")
    let text = String(repeating: "Short sentence here. ", count: 40)
    let chunks = SupertonicPipeline.chunks(text, maxLength: 120)
    print("C", chunks.count, chunks.allSatisfy { $0.count <= 120 }, chunks.joined(separator: " ").split(separator: " ").count)
    let long = String(repeating: "あ", count: 300)
    let jp = SupertonicPipeline.chunks(long, maxLength: 120)
    print("D", jp.map(\.count))
}
