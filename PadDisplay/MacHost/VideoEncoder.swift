import CoreMedia
import Foundation
import VideoToolbox

enum EncoderError: LocalizedError {
    case createFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createFailed(let status): return "HEVC 인코더 생성 실패 (\(status))"
        }
    }
}

/// Apple Silicon 미디어 엔진 기반 실시간 HEVC 인코더.
final class VideoEncoder {
    struct EncodedFrame {
        let data: Data
        let isKeyframe: Bool
        let parameterSets: [Data]
        let width: Int
        let height: Int
        let ptsMicros: Int64
    }

    /// VideoToolbox 내부 스레드에서 직렬로 호출된다.
    var onEncoded: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var keyframeRequested = true

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        // 저지연 레이트 컨트롤을 먼저 시도하고, 미지원이면 일반 실시간 모드로 폴백.
        var status: OSStatus = noErr
        var created: VTCompressionSession?
        for lowLatency in [true, false] {
            (created, status) = Self.makeSession(width: width, height: height, lowLatency: lowLatency)
            if created != nil { break }
        }
        guard let session = created else { throw EncoderError.createFailed(status) }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // B프레임 없음
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bitrate / 8 * 3 / 2), NSNumber(value: 1)] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        // 키프레임은 요청 시(연결·패킷 손실·혼잡)에만. 주기 키프레임은 10초 보험.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 10))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 10))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    func forceKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock()
        let forceKey = keyframeRequested
        keyframeRequested = false
        lock.unlock()

        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props,
                                                     infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handle(sampleBuffer)
        }
        if status != noErr, forceKey { forceKeyframe() }
    }

    func invalidate() {
        onEncoded = nil
        guard let session else { return }
        self.session = nil
        VTCompressionSessionInvalidate(session)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let first = attachments.first {
            isKeyframe = !((first[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false)
        }

        var sets: [Data] = []
        var width = 0, height = 0
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            width = Int(dims.width)
            height = Int(dims.height)
            if isKeyframe { sets = Self.parameterSets(of: format) }
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onEncoded?(EncodedFrame(data: data, isKeyframe: isKeyframe, parameterSets: sets,
                                width: width, height: height,
                                ptsMicros: Int64(CMTimeGetSeconds(pts) * 1_000_000)))
    }

    private static func makeSession(width: Int, height: Int, lowLatency: Bool) -> (VTCompressionSession?, OSStatus) {
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
        return (status == noErr ? session : nil, status)
    }

    private static func parameterSets(of format: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
                                                                 parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil,
                                                                 parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil) == noErr
        else { return [] }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                                                  parameterSetPointerOut: &pointer,
                                                                  parameterSetSizeOut: &size,
                                                                  parameterSetCountOut: nil,
                                                                  nalUnitHeaderLengthOut: nil) == noErr,
               let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}
