import AppKit
import SatsumaCore

/// Tiny synthesized UI sounds (no audio files), the same tones as the Windows app.
enum SoundFx {
    enum Cue { case open, tick, switchWheel, commit, done, error }

    private static var sounds: [Cue: NSSound] = [:]

    static func play(_ cue: Cue) {
        guard Settings.current.sounds, !Runtime.isTestMode else { return }
        let sound = sounds[cue] ?? make(cue)
        sounds[cue] = sound
        // A copy lets quick repeats (hover ticks) overlap instead of being dropped.
        if sound.isPlaying { (sound.copy() as? NSSound)?.play() } else { sound.play() }
    }

    private static func tone(_ t: Double, _ hz: Double) -> Double { sin(2 * .pi * hz * t) }

    private static func env(_ t: Double, _ attack: Double, _ decay: Double) -> Double {
        if t < 0 { return 0 }
        if t < attack { return t / attack }
        return exp(-(t - attack) / decay)
    }

    private static func make(_ cue: Cue) -> NSSound {
        switch cue {
        case .open: return wav(0.07, 0.11) { tone($0, 520 + 300 * $0 / 0.07) * env($0, 0.003, 0.05) }
        case .tick: return wav(0.016, 0.06) { tone($0, 2600) * env($0, 0.0008, 0.006) }
        case .switchWheel: return wav(0.05, 0.08) { tone($0, 680 + 260 * $0 / 0.05) * env($0, 0.002, 0.03) }
        case .commit: return wav(0.11, 0.11) { (tone($0, 880) * 0.6 + tone($0, 1320) * 0.4) * env($0, 0.002, 0.06) }
        case .done: return wav(0.26, 0.11) { t in t < 0.11 ? tone(t, 784) * env(t, 0.003, 0.07) : tone(t, 1175) * env(t - 0.11, 0.003, 0.1) }
        case .error: return wav(0.18, 0.1) { (tone($0, 220) + 0.4 * tone($0, 330)) * env($0, 0.004, 0.09) }
        }
    }

    private static func wav(_ seconds: Double, _ volume: Double, _ wave: (Double) -> Double) -> NSSound {
        let rate = 44_100
        let n = Int(seconds * Double(rate))
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 2); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n * 2)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let fadeOut = min(1, Double(n - i) / (Double(rate) * 0.004)) // avoid clicks at the end
            let v = max(-1, min(1, wave(t) * volume * fadeOut))
            u16(Int(UInt16(bitPattern: Int16(v * 32767))))
        }
        return NSSound(data: d) ?? NSSound()
    }
}
