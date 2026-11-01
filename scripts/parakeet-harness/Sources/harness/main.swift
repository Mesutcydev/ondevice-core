@_exported import OnnxRuntimeBindings
import AVFoundation
import Foundation

// Mac check for the app's ParakeetTranscriber (same source file, symlinked):
//   swift run -c release harness <model dir> <16 kHz mono .wav>...
// <model dir> is a download of istupakov/parakeet-tdt-0.6b-v3-onnx
// (nemo128.onnx, encoder/decoder_joint int8, vocab.txt). Compare the output
// with `onnx_asr.load_model("nemo-parakeet-tdt-0.6b-v3", dir, quantization="int8")`.
let start = Date()
let transcriber = try ParakeetTranscriber(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
print(String(format: "load %.2fs", Date().timeIntervalSince(start)))
for path in CommandLine.arguments.dropFirst(2) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let t = Date()
    let text = try transcriber.transcribe(samples)
    print("\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)\t\(text)\t(\(String(format: "%.2fs", Date().timeIntervalSince(t))))")
}
