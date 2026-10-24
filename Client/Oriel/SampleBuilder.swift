import Foundation
import CoreMedia
import VideoToolbox

/// Turns protocol video payloads into `CMSampleBuffer`s for
/// `AVSampleBufferDisplayLayer`, which decodes and composites them in hardware.
///
/// Building sample buffers ourselves (rather than decoding to pixel buffers in
/// app code) keeps the frames on one path: no per-frame main-thread upload, no
/// clock synchronisation against the host's timestamps.
final class SampleBuilder {

    private let queue = DispatchQueue(label: "dev.igho.remotemac.sample", qos: .userInteractive)
    private var format: CMFormatDescription?
    private var waitingForKeyframe = true

    /// Delivered on the main actor.
    var onSample: ((CMSampleBuffer) -> Void)?

    func configure(_ config: VideoConfig) throws {
        var thrown: Error?
        queue.sync {
            do {
                format = try Self.makeFormatDescription(config)
                waitingForKeyframe = true
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    func reset() {
        queue.async {
            self.format = nil
            self.waitingForKeyframe = true
        }
    }

    func feed(_ payload: Data) {
        queue.async { [weak self] in
            self?.build(payload)
        }
    }

    // MARK: - Internals

    private func build(_ payload: Data) {
        guard let header = VideoFrameHeader.decode(payload), let format else { return }

        let isKeyframe = header.flags & VideoFrameHeader.flagsKeyframe != 0
        if waitingForKeyframe {
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }

        let nal = payload.subdata(in: VideoFrameHeader.byteCount..<payload.count)
        guard !nal.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: nal.count,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: nal.count,
                                                 flags: 0,
                                                 blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { return }

        let copied = nal.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: nal.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: header.presentationMicros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = nal.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: blockBuffer,
                                        formatDescription: format,
                                        sampleCount: 1,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }

        // Host timestamps are on a different clock; show frames as they arrive
        // instead of letting the layer schedule them against local time.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        DispatchQueue.main.async { [weak self] in
            self?.onSample?(sampleBuffer)
        }
    }

    private static func makeFormatDescription(_ config: VideoConfig) throws -> CMFormatDescription {
        let sets = config.parameterSets.compactMap { Data(base64Encoded: $0) }
        guard !sets.isEmpty else {
            throw NSError(domain: "RemoteMac.Decoder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Host sent no HEVC parameter sets"])
        }

        var description: CMFormatDescription?
        var status: OSStatus = -1

        // Pointers into `Data` are only valid inside their `withUnsafeBytes`
        // closure, so nest the calls instead of collecting the pointers into an
        // array first — that escapes the buffers and the C call then reads freed
        // memory (which fails as -12712 on iOS).
        func build(_ index: Int, _ pointers: [UnsafePointer<UInt8>], _ sizes: [Int]) {
            guard index < sets.count else {
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(config.nalUnitHeaderLength),
                    extensions: nil,
                    formatDescriptionOut: &description)
                return
            }
            sets[index].withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                build(index + 1, pointers + [base], sizes + [raw.count])
            }
        }
        build(0, [], [])

        guard status == noErr, let description else {
            throw NSError(domain: "RemoteMac.Decoder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Bad HEVC parameter sets (\(status))"])
        }
        return description
    }
}
