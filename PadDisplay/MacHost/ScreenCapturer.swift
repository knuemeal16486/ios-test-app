import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "가상 디스플레이를 ScreenCaptureKit에서 찾지 못했습니다 (화면 기록 권한 확인)."
        }
    }
}

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "paddisplay.capture", qos: .userInteractive)

    /// `queue`에서 호출. 화면 변화가 없으면 프레임이 오지 않는다.
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var target: SCDisplay?
        for _ in 0..<30 { // 새 가상 디스플레이가 목록에 나타날 때까지 대기
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else { throw CaptureError.displayNotFound }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // 인코더 입력과 동일 → 변환 없음
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = false

        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
