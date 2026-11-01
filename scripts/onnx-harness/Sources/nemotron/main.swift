@_exported import OnnxRuntimeBindings
import AVFoundation
import Foundation

// Mac check for the app's NemotronTranscriber (same source file, symlinked):
//   swift run -c release nemotron <model dir> <lang>=<16 kHz mono .wav>...
// <model dir> is a download of soniqo/Nemotron-3.5-ASR-Streaming-Multilingual-0.6B-ONNX-INT8.
let start = Date()
let transcriber = try NemotronTranscriber(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
print(String(format: "load %.2fs", Date().timeIntervalSince(start)))
for argument in CommandLine.arguments.dropFirst(2) {
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: parts[1]), commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let t = Date()
    let text = try transcriber.transcribe(samples, language: parts[0])
    print("\(parts[0])\t\(text)\t(\(String(format: "%.2fs for %.1fs audio", Date().timeIntervalSince(t), Double(samples.count) / 16000)))")
}
