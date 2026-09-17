/// Audio measurement helpers shared by the ASR engines and the session log.
enum AudioLevels {
    /// Chunk RMS at or below which a chunk counts as silence: −60 dBFS,
    /// matching `AudioLevelState`'s meter floor. The no-audio watchdog treats
    /// a capture that never exceeds it as denied or muted.
    static let silenceFloorRMS: Float = 0.001

    /// Root-mean-square energy of a PCM buffer (0 for empty input). The
    /// shared loudness metric behind the ASR speech backstop and the debug
    /// ingress log.
    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0) { partial, sample in partial + sample * sample }
        return (energy / Float(samples.count)).squareRoot()
    }
}
