import AVFoundation

/// A one-second, two-note bell chime, synthesized in code.
///
/// The audio engine runs only while the chime plays, so Jit never holds the audio
/// hardware open (which would keep the Mac from idle-sleeping).
final class Chime {
    var volume: Float = 0.7

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer
    private var generation = 0

    init() {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate)  // 1 second
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        let notes: [(start: Double, hz: Double)] = [(0, 1318.51), (0.13, 1975.53)]  // E6, then B6
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            var sample = 0.0
            for note in notes where t >= note.start {
                let u = t - note.start
                let envelope = min(u / 0.004, 1) * exp(-u / 0.2)  // 4 ms attack, bell-like decay
                let w = 2 * Double.pi * note.hz * u
                sample += envelope * (sin(w) + 0.3 * sin(2 * w) + 0.12 * sin(3.01 * w))
            }
            out[i] = Float(sample * 0.25)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play() {
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            NSLog("Jit: couldn't start audio: %@", error.localizedDescription)
            return
        }
        generation += 1
        let mine = generation
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                self.player.stop()
                self.engine.stop()
            }
        }
        player.play()
    }
}
