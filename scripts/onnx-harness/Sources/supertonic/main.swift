@_exported import OnnxRuntimeBindings
import Foundation

// Mac check for the app's SupertonicPipeline (same source file, symlinked):
//   swift run -c release supertonic selftest            text normalizer and chunker
//   swift run -c release supertonic <model dir> <out>   one WAV per language
// <model dir> is a download of Supertone/supertonic-3 (onnx/, voice_styles/).
// Transcribe the WAVs (e.g. whisper-cli) to confirm they say the input text.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "selftest" { selftest(); exit(0) }
let model = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let pipeline = try SupertonicPipeline(directory: model)
let style = try SupertonicPipeline.loadStyle(model.appendingPathComponent("voice_styles/F1.json"))
let samples: [(String, String)] = [
    ("en", "Hello! This is Token AI speaking with Supertonic, entirely on your iPhone."),
    ("tr", "Merhaba! Bu ses tamamen telefonunuzda üretiliyor."),
    ("de", "Guten Morgen. Ich wünsche dir einen wunderschönen Tag."),
    ("ja", "こんにちは。今日はいい天気ですね。"),
]
for (lang, text) in samples {
    let start = Date()
    let wav = try pipeline.synthesize(text, language: lang, style: style)
    let elapsed = Date().timeIntervalSince(start)
    let seconds = Double(wav.count) / Double(pipeline.sampleRate)
    let rms = (wav.reduce(0) { $0 + $1 * $1 } / Float(max(wav.count, 1))).squareRoot()
    var pcm = Data()
    for s in wav { var v = Int16(max(-1, min(1, s)) * 32767); pcm.append(Data(bytes: &v, count: 2)) }
    var header = Data("RIFF".utf8)
    func u32(_ x: Int) { var v = UInt32(x); header.append(Data(bytes: &v, count: 4)) }
    func u16(_ x: Int) { var v = UInt16(x); header.append(Data(bytes: &v, count: 2)) }
    u32(36 + pcm.count); header.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(pipeline.sampleRate); u32(pipeline.sampleRate * 2); u16(2); u16(16)
    header.append(Data("data".utf8)); u32(pcm.count)
    try (header + pcm).write(to: out.appendingPathComponent("\(lang).wav"))
    print(String(format: "%@ %.2fs audio, rms %.3f, %.2fs compute (RTF %.2f), finite=%@",
                 lang, seconds, rms, elapsed, elapsed / max(seconds, 0.001), wav.allSatisfy(\.isFinite) ? "yes" : "NO"))
}
