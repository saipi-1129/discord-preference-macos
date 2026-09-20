import AVFoundation

class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    #if os(iOS)
    private var audioPlayer: AVAudioPlayer?
    #endif

    func start() {
        #if os(macOS)
        print("[BG Audio] Not required on macOS")
        #else
        guard audioPlayer == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            print("[BG Audio] Session setup failed: \(error)")
            return
        }


        // Generate a tiny silent WAV in memory (1 second, 8kHz, mono, 16-bit)
        let silentData = generateSilentWAV(durationSeconds: 1)
        do {
            let player = try AVAudioPlayer(data: silentData)
            player.numberOfLoops = -1 // Loop forever
            player.volume = 0.0
            player.play()
            audioPlayer = player
            print("[BG Audio] Started")
        } catch {
            print("[BG Audio] Player failed: \(error)")
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        print("[BG Audio] Stopped")
        #else
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[BG Audio] Stopped")
        #endif
    }

    #if os(iOS)
    private func generateSilentWAV(durationSeconds: Double) -> Data {
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples = UInt32(Double(sampleRate) * durationSeconds)
        let dataSize = numSamples * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let fileSize = 36 + dataSize

        var data = Data()
        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = numChannels * (bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.append(Data(count: Int(dataSize))) // silence
        return data
    }
    #endif
}
