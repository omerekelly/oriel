import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreAudio

struct EncodedFrame {
    let data: Data            // AVCC, 4-byte length-prefixed NAL units
    let isKeyframe: Bool
    let presentationMicros: Int64
    var gapMillis: UInt16 = 0
    var sequence: UInt32 = 0
}

/// Captures a display with ScreenCaptureKit and encodes it to HEVC with
/// VideoToolbox. Runs entirely on its own serial queue; results are handed back
/// on the caller's thread via the callbacks.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    enum StartError: LocalizedError {
        case noDisplays
        case streamFailed(String)
        case encoderFailed(OSStatus)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplays: return "No capturable display found."
            case .streamFailed(let m): return "Screen capture failed: \(m)"
            case .encoderFailed(let s): return "Could not create the video encoder (status \(s))."
            case .permissionDenied: return "Screen Recording permission is not granted."
            }
        }
    }

    private let queue = DispatchQueue(label: "dev.igho.remotemac.capture", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "dev.igho.remotemac.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var sessionConfig: (width: Int, height: Int)?
    private var sentParams = false
    private var forceNextKeyframe = false
    private var streamWidth = 0
    private var streamHeight = 0
    private var streamFPS = 30
    private var currentDisplay: SCDisplay?
    private var displayPointBounds: CGRect = .zero
    private var appliedViewport: Viewport = .full
    private var audioConfigSent = false
    private var audioFormatLogged = false
    private var audioLevelLogged = false
    private var audioChunkCount = 0
    private var audioErrorLogged = false
    private(set) var audioConfig: AudioConfig = .defaultPCM
    private(set) var bitrate = 6_000_000
    private(set) var audioBytesSent = 0
    private var lastConfig: VideoConfig?
    private var lastSentFrameTime: CMTime = .invalid
    private var frameCount = 0
    private var startedAt = Date()

    private(set) var displayInfo: DisplayInfo?
    private(set) var displays: [DisplayDescriptor] = []
    private(set) var activeDisplayID: UInt32?
    var onFrame: ((EncodedFrame) -> Void)?
    var onVideoConfig: ((VideoConfig) -> Void)?
    var onAudioConfig: ((AudioConfig) -> Void)?
    var onAudioDiagnostic: ((String) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?

    var measuredFPS: Double {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return 0 }
        return Double(frameCount) / elapsed
    }

    var capturedSize: CGSize {
        guard let c = sessionConfig else { return .zero }
        return CGSize(width: c.width, height: c.height)
    }

    // MARK: - Lifecycle

    func start(maxDimension: Int, fps: Int, displayID: UInt32? = nil) async throws {
        guard stream == nil else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw StartError.streamFailed(error.localizedDescription)
        }

        displays = content.displays.map { candidate in
            let isMain = candidate.displayID == CGMainDisplayID()
            return DisplayDescriptor(id: candidate.displayID,
                                     name: isMain ? "Main Display" : "Display \(candidate.displayID)",
                                     pixelWidth: candidate.width,
                                     pixelHeight: candidate.height,
                                     isMain: isMain)
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else { throw StartError.noDisplays }
        activeDisplayID = display.displayID

        let aspect = Double(display.height) / Double(display.width)
        let targetWidth = min(maxDimension, display.width)
        let targetHeight = Int((Double(targetWidth) * aspect).rounded())
        let evenW = targetWidth - (targetWidth % 2)
        let evenH = targetHeight - (targetHeight % 2)

        let pointBounds = CGDisplayBounds(display.displayID)
        displayInfo = DisplayInfo(displayID: display.displayID,
                                  pixelWidth: evenW,
                                  pixelHeight: evenH,
                                  pointWidth: Double(pointBounds.width),
                                  pointHeight: Double(pointBounds.height),
                                  name: display.displayID == CGMainDisplayID() ? "Main Display" : "Display \(display.displayID)")

        try createEncoder(width: evenW, height: evenH, fps: fps)
        sessionConfig = (evenW, evenH)
        sentParams = false
        frameCount = 0
        startedAt = Date()

        streamWidth = evenW
        streamHeight = evenH
        streamFPS = fps
        currentDisplay = display
        displayPointBounds = pointBounds
        appliedViewport = .full

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = makeConfiguration(viewport: .full)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
        } catch {
            // Leave no half-initialised state behind, or a retry would think
            // capture is already running.
            displayInfo = nil
            sessionConfig = nil
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            throw error
        }
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sessionConfig = nil
        appliedViewport = .full
        audioConfigSent = false
        audioFormatLogged = false
        audioLevelLogged = false
        audioChunkCount = 0
        audioErrorLogged = false
        onStopped?()
    }

    // MARK: - Viewport

    private func makeConfiguration(viewport: Viewport) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = streamWidth
        config.height = streamHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(streamFPS, 5)))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.shouldBeOpaque = true
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB

        if !viewport.isFullFrame {
            let r = viewport.rect
            let b = displayPointBounds
            config.sourceRect = CGRect(x: b.minX + r.x * b.width,
                                       y: b.minY + r.y * b.height,
                                       width: r.w * b.width,
                                       height: r.h * b.height)
        }
        return config
    }

    /// Reconfigures the live stream to capture only `viewport`, still encoded at
    /// the full output size, so the cropped region arrives at its native
    /// detail rather than being magnified later.
    func apply(viewport: Viewport) async {
        guard let stream, currentDisplay != nil, streamWidth > 0 else { return }
        let clamped = viewport.clamped
        appliedViewport = clamped
        do {
            try await stream.updateConfiguration(makeConfiguration(viewport: clamped))
            requestKeyframe()
        } catch {
            onError?("Viewport update failed: \(error.localizedDescription)")
        }
    }

    var viewport: Viewport { appliedViewport }

    // MARK: - Encoder

    private func createEncoder(width: Int, height: Int, fps: Int) throws {
        var created: VTCompressionSession?
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: false
        ]
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: attrs as CFDictionary,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil,
                                                refcon: nil,
                                                compressionSessionOut: &created)
        guard status == noErr, let created else { throw StartError.encoderFailed(status) }

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // ~7 Mbps ceiling for a laptop-sized desktop; bitrate-limited rather than
        // quality-limited so the client never gets starved behind a slow link.
        let bitrate = max(3_000_000, min(9_000_000, width * height * 3))
        self.bitrate = bitrate
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        let limitBytes = bitrate / 8
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [limitBytes, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            handleAudio(sampleBuffer)
            return
        }
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }
        guard let session else { return }

        var frameProperties: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: frameProperties,
                                        infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard let self, status == noErr, let encoded else { return }
            self.handleEncoded(encoded)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamStopped(error.localizedDescription)
    }

    private func streamStopped(_ message: String) {
        onError?(message)
        queue.async { [weak self] in
            guard let self else { return }
            self.stream = nil
            if let session = self.session {
                VTCompressionSessionInvalidate(session)
                self.session = nil
            }
            self.onStopped?()
        }
    }

    // MARK: - Audio

    /// ScreenCaptureKit hands back float32 audio (usually non-interleaved). The
    /// client wants interleaved Int16 so it can schedule it straight into an
    /// AVAudioPlayerNode, and silence is dropped rather than spending ~1.5 Mbps
    /// on an idle desktop.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        let asbd = asbdPointer.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate
        guard channels > 0, sampleRate > 0 else { return }

        if !audioConfigSent {
            audioConfigSent = true
            let config = AudioConfig(sampleRate: sampleRate, channels: channels)
            audioConfig = config
            onAudioConfig?(config)
        }

        // ScreenCaptureKit delivers non-interleaved audio, so a single
        // AudioBufferList on the stack is too small: stereo needs two entries.
        // Ask for the required size first, then allocate.
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil)
        guard needed > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else {
            if !audioErrorLogged {
                audioErrorLogged = true
                onError?("Audio buffer list failed: \(status)")
            }
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, !buffers.isEmpty else { return }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        if !audioFormatLogged {
            audioFormatLogged = true
            let byteSizes = (0..<buffers.count).map { Int(buffers[$0].mDataByteSize) }
            onAudioDiagnostic?("audio input: \(Int(sampleRate)) Hz, \(channels) ch, "
                + "\(asbd.mBitsPerChannel) bits, float=\(isFloat), nonInterleaved=\(isNonInterleaved), "
                + "buffers=\(buffers.count), bytes=\(byteSizes)")
        }
        var pcm = [Int16](repeating: 0, count: frameCount * channels)

        if isFloat {
            let scale = 32767.0
            if isNonInterleaved {
                for channel in 0..<min(channels, buffers.count) {
                    guard let raw = buffers[channel].mData else { continue }
                    let source = raw.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameCount {
                        pcm[frame * channels + channel] = Int16(max(-1, min(1, source[frame])) * Float(scale))
                    }
                }
            } else if let raw = buffers[0].mData {
                let source = raw.assumingMemoryBound(to: Float.self)
                let total = min(frameCount * channels, Int(buffers[0].mDataByteSize) / 4)
                for index in 0..<total {
                    pcm[index] = Int16(max(-1, min(1, source[index])) * Float(scale))
                }
            }
        } else if let raw = buffers[0].mData {
            let source = raw.assumingMemoryBound(to: Int16.self)
            let total = min(frameCount * channels, Int(buffers[0].mDataByteSize) / 2)
            for index in 0..<total { pcm[index] = source[index] }
        }

        // Drop near-silence.
        var sumSquares = 0.0
        for value in pcm {
            let sample = Double(value) / 32768.0
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Double(pcm.count)).squareRoot()
        audioChunkCount += 1
        if audioChunkCount % 100 == 1 {
            onAudioDiagnostic?("audio chunk #\(audioChunkCount): \(frameCount) frames, rms=\(String(format: "%.4f", rms))")
        }
        guard rms > 0.0025 else { return }

        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        audioBytesSent += data.count
        onAudio?(data)
    }

    // MARK: - Output

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        if sentParams == false || (isKeyframe && !sentParams) {
            if !isKeyframe { return }   // wait for a keyframe before announcing params
            if let config = makeVideoConfig(format: format) {
                sentParams = true
                lastConfig = config
                onVideoConfig?(config)
            }
        }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let st = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                             lengthAtOffsetOut: nil,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &pointer)
        guard st == kCMBlockBufferNoErr, let pointer, totalLength > 0 else { return }

        let data = Data(bytes: pointer, count: totalLength)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var gap: UInt16 = 0
        if lastSentFrameTime.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastSentFrameTime))
            gap = UInt16(max(0, min(Double(UInt16.max), delta * 1000)))
        }
        lastSentFrameTime = pts
        frameCount += 1

        var frame = EncodedFrame(data: data,
                                 isKeyframe: isKeyframe,
                                 presentationMicros: Int64(CMTimeGetSeconds(pts) * 1_000_000))
        frame.gapMillis = gap
        onFrame?(frame)
    }

    private func makeVideoConfig(format: CMFormatDescription) -> VideoConfig? {
        var count = 0
        var headerLength: Int32 = 4
        let probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,
                                                                       parameterSetIndex: 0,
                                                                       parameterSetPointerOut: nil,
                                                                       parameterSetSizeOut: nil,
                                                                       parameterSetCountOut: &count,
                                                                       nalUnitHeaderLengthOut: &headerLength)
        guard probe == noErr, count > 0 else { return nil }

        var sets: [String] = []
        for index in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,
                                                                        parameterSetIndex: index,
                                                                        parameterSetPointerOut: &ptr,
                                                                        parameterSetSizeOut: &size,
                                                                        parameterSetCountOut: nil,
                                                                        nalUnitHeaderLengthOut: nil)
            guard st == noErr, let ptr, size > 0 else { return nil }
            sets.append(Data(bytes: ptr, count: size).base64EncodedString())
        }

        let size = sessionConfig ?? (0, 0)
        return VideoConfig(codec: "hevc",
                           width: size.width,
                           height: size.height,
                           parameterSets: sets,
                           nalUnitHeaderLength: Int(headerLength))
    }

    var isStreaming: Bool { stream != nil }

    /// Adjusts the encoder's ceiling while it runs. This is the main lever for
    /// adapting to a slow link: resolution changes force keyframes and a
    /// reconfiguration, bitrate changes are cheap.
    func setBitrate(_ bitsPerSecond: Int) {
        let clamped = max(1_500_000, min(12_000_000, bitsPerSecond))
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            guard abs(clamped - self.bitrate) > 300_000 else { return }
            self.bitrate = clamped
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: clamped as CFNumber)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: [clamped / 8, 1] as CFArray)
        }
    }

    /// Forces the next encoded frame to be a keyframe. Used when a new client
    /// attaches so it does not have to wait out the GOP interval.
    func requestKeyframe() {
        guard session != nil else { return }
        queue.async { [weak self] in
            self?.forceNextKeyframe = true
        }
    }

    /// Re-announces the last parameter sets to a newly attached client, then
    /// forces a keyframe so that client can start decoding immediately.
    func greetNewClient() -> VideoConfig? {
        guard session != nil, let config = lastConfig else { return nil }
        requestKeyframe()
        return config
    }
}
