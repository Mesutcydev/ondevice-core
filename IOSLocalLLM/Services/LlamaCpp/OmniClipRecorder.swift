import Foundation
import AVFoundation

#if LFM3_OMNI
/// Microphone for a Lens clip: 16 kHz mono float into a temporary file,
/// under the shared audio-session lease. Without permission or input the
/// clip is frames only.
@MainActor
final class OmniClipRecorder {
    private let owner = UUID()
    private var recorder: AVAudioRecorder?

    func start() async -> URL? {
        guard await AVAudioApplication.requestRecordPermission() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-clip-\(UUID().uuidString).caf")
        let policy = VoiceAudioSessionManager.policy(for: .listening)
        VoiceAudioSessionManager.shared.acquire(owner)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(policy.category, mode: policy.mode, options: policy.options)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ])
            guard recorder.record() else {
                stop()
                return nil
            }
            self.recorder = recorder
            return url
        } catch {
            stop()
            return nil
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        VoiceAudioSessionManager.shared.release(owner, deactivateIfUnused: true)
    }
}
#endif
