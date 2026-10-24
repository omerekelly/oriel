import Foundation
import AVFoundation

/// Plays the host's system audio.
///
/// The host sends interleaved Int16 PCM, which is turned into float buffers and
/// scheduled on a player node. The audio session uses `.playback` so the stream
/// is audible even when the iPhone's silent switch is on — otherwise "remote
/// desktop with no sound" is exactly what you get.
final class AudioPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var attached = false
    private var running = false

    // Keeps latency bounded if the network delivers a burst: at ~21 ms per
    // buffer, this is about 160 ms of queued audio.
    private let maxQueuedBuffers = 8
    private var queuedBuffers = 0

    func start(with config: AudioConfig) {
        stop()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: [])

        // Must be the standard (deinterleaved float32) format: connecting an
        // interleaved format to the engine's mixer raises an ObjC exception from
        // AVAudioEngineGraph::_Connect and aborts the app.
        let rate = config.sampleRate > 8000 && config.sampleRate < 192_000 ? config.sampleRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: AVAudioChannelCount(max(1, min(2, config.channels)))) else { return }
        self.format = format

        engine.attach(player)
        attached = true
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            stop()
            return
        }
        player.play()
        running = true
        queuedBuffers = 0
    }

    func stop() {
        if running {
            player.stop()
            engine.stop()
        }
        running = false
        if attached {
            engine.detach(player)
            attached = false
        }
        format = nil
        queuedBuffers = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func enqueue(_ pcm: Data) {
        guard running, let format else { return }
        let channels = Int(format.channelCount)
        let bytesPerFrame = MemoryLayout<Int16>.size * channels
        let frames = pcm.count / bytesPerFrame
        guard frames > 0 else { return }

        // Drop everything if we have fallen too far behind, rather than drifting
        // into a permanently delayed stream.
        if queuedBuffers >= maxQueuedBuffers {
            player.stop()
            player.play()
            queuedBuffers = 0
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)

        pcm.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            let available = source.count
            guard let channelData = buffer.floatChannelData else { return }
            for channel in 0..<channels {
                let destination = channelData[channel]
                for frame in 0..<frames {
                    let index = frame * channels + channel
                    guard index < available else { break }
                    destination[frame] = Float(source[index]) / 32768.0
                }
            }
        }

        queuedBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async { self?.queuedBuffers = max(0, (self?.queuedBuffers ?? 1) - 1) }
        }
    }
}
