import AVFoundation
import CoreMedia

/// HEVC 스트림을 AVSampleBufferDisplayLayer(하드웨어 디코드)로 즉시 표시.
/// setFormat / enqueue 는 네트워크 큐에서, reset / videoSize 는 메인에서 호출될 수 있다.
final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()

    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var awaitingKeyframe = true
    private var size = CGSize.zero

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    var videoSize: CGSize { lock.withLock { size } }

    func reset() {
        lock.withLock {
            format = nil
            awaitingKeyframe = true
        }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func setFormat(_ message: VideoFormatMessage) {
        let newFormat = Self.makeFormat(message.parameterSets)
        lock.withLock {
            format = newFormat
            if let newFormat {
                let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
                size = CGSize(width: Int(dims.width), height: Int(dims.height))
            }
        }
    }

    /// false 반환 시 호출 측이 키프레임을 요청해야 한다.
    func enqueue(_ frame: VideoFrameMessage) -> Bool {
        let renderer = layer.sampleBufferRenderer
        lock.lock()
        defer { lock.unlock() }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            awaitingKeyframe = true
        }
        guard let format else { return false }
        if awaitingKeyframe {
            guard frame.isKeyframe else { return false }
            awaitingKeyframe = false
        }
        guard let sample = Self.makeSampleBuffer(frame, format: format) else {
            awaitingKeyframe = true
            return false
        }
        renderer.enqueue(sample)
        return true
    }

    private static func makeFormat(_ parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let pointers: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = parameterSets.map { $0.count }

        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSets.count,
            parameterSetPointers: constPointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private static func makeSampleBuffer(_ frame: VideoFrameMessage, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let count = frame.payload.count
        guard count > 0 else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block
        else { return nil }

        let copyStatus = frame.payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: frame.ptsMicros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr,
              let sample
        else { return nil }

        // 타임베이스 무시하고 도착 즉시 표시 (지연 최소화)
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
