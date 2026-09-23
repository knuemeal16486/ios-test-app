import AVFoundation
import UIKit

@MainActor
protocol RemoteInputSink: AnyObject {
    /// iPad 1pt 당 Mac 포인트 (스크롤 델타 환산용)
    var pointScale: CGFloat { get }
    func send(_ event: InputEvent)
    func toggleHUD()
    func viewSizeChanged(pixels: CGSize, points: CGSize)
}

/// 원격 화면 표시 + 입력 수집.
///
/// 제스처 매핑
/// - 1손가락/펜슬 탭: 클릭 (연속 탭 → 더블클릭)
/// - 1손가락/펜슬 드래그: 클릭-드래그
/// - 2손가락 드래그: 스크롤 (관성 포함) / 트랙패드·마우스 휠도 동일
/// - 2손가락 탭, 길게 누르기, 보조 클릭: 우클릭
/// - 3손가락 탭: HUD 표시
/// - 트랙패드·마우스 이동, 펜슬 호버: 포인터 이동
final class RemoteDisplayView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    weak var sink: RemoteInputSink?
    var onInteraction: (() -> Void)?

    private let displayLayer: AVSampleBufferDisplayLayer
    private let videoSize: () -> CGSize

    private var momentumLink: CADisplayLink?
    private var momentumVelocity = CGPoint.zero
    private var momentumStarted = false
    private var lastMomentumTime: CFTimeInterval = 0

    init(displayLayer: AVSampleBufferDisplayLayer, videoSize: @escaping () -> CGSize) {
        self.displayLayer = displayLayer
        self.videoSize = videoSize
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        layer.addSublayer(displayLayer)
        setupGestures()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        let scale = traitCollection.displayScale
        sink?.viewSizeChanged(pixels: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                              points: bounds.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        onInteraction?()
        super.touchesBegan(touches, with: event)
    }

    // MARK: - Gestures

    private var scrollWheel: UIPanGestureRecognizer!

    private func setupGestures() {
        let hud = UITapGestureRecognizer(target: self, action: #selector(handleHUD(_:)))
        hud.numberOfTouchesRequired = 3

        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryTap(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        secondaryTap.require(toFail: hud)

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryTap(_:)))
        secondaryClick.buttonMaskRequired = .secondary

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: secondaryTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2

        // 트랙패드 2손가락 스크롤 / 마우스 휠 전용 (터치 없음)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        scrollWheel = wheel

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))

        for recognizer in [hud, secondaryTap, secondaryClick, tap, longPress, drag, scroll, wheel, hover] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer
    }

    @objc private func handleHUD(_ recognizer: UITapGestureRecognizer) {
        sink?.toggleHUD()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        click(.left, at: recognizer.location(in: self))
    }

    @objc private func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
        click(.right, at: recognizer.location(in: self))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        click(.right, at: recognizer.location(in: self))
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: sendMove(recognizer.location(in: self))
        default: break
        }
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            // 인식 임계값만큼 이동한 뒤 시작되므로 실제 터치 시작점에서 누른다.
            let translation = recognizer.translation(in: self)
            let start = normalized(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
            sink?.send(.move(x: start.x, y: start.y))
            sink?.send(.button(button: .left, down: true, x: start.x, y: start.y))
            sendMove(location)
        case .changed:
            sendMove(location)
        case .ended, .cancelled, .failed:
            let end = normalized(location)
            sink?.send(.button(button: .left, down: false, x: end.x, y: end.y))
        default:
            break
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let scale = sink?.pointScale ?? 1
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let dx = Double(translation.x * scale), dy = Double(translation.y * scale)

        switch recognizer.state {
        case .began:
            stopMomentum()
            if recognizer !== scrollWheel { sendMove(recognizer.location(in: self)) }
            sink?.send(.scroll(dx: dx, dy: dy, phase: .began))
        case .changed:
            sink?.send(.scroll(dx: dx, dy: dy, phase: .changed))
        case .ended:
            sink?.send(.scroll(dx: 0, dy: 0, phase: .ended))
            let velocity = recognizer.velocity(in: self)
            startMomentum(CGPoint(x: velocity.x * scale, y: velocity.y * scale))
        case .cancelled, .failed:
            sink?.send(.scroll(dx: 0, dy: 0, phase: .ended))
        default:
            break
        }
    }

    // MARK: - Momentum scrolling

    private func startMomentum(_ velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 150 else { return }
        momentumVelocity = velocity
        momentumStarted = false
        lastMomentumTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastMomentumTime
        lastMomentumTime = now
        let decay = CGFloat(pow(0.998, dt * 1000)) // UIScrollView.DecelerationRate.normal
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        guard hypot(momentumVelocity.x, momentumVelocity.y) > 20 else {
            stopMomentum()
            return
        }
        sink?.send(.scroll(dx: Double(momentumVelocity.x * dt), dy: Double(momentumVelocity.y * dt),
                           phase: momentumStarted ? .momentum : .momentumBegan))
        momentumStarted = true
    }

    private func stopMomentum() {
        guard let link = momentumLink else { return }
        link.invalidate()
        momentumLink = nil
        if momentumStarted { sink?.send(.scroll(dx: 0, dy: 0, phase: .momentumEnded)) }
        momentumStarted = false
    }

    // MARK: - Pointer

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden() // Mac 커서가 영상에 그려지므로 iPad 포인터는 숨김
    }

    // MARK: - Helpers

    private func click(_ button: MouseButton, at point: CGPoint) {
        onInteraction?()
        let p = normalized(point)
        sink?.send(.move(x: p.x, y: p.y))
        sink?.send(.button(button: button, down: true, x: p.x, y: p.y))
        sink?.send(.button(button: button, down: false, x: p.x, y: p.y))
    }

    private func sendMove(_ point: CGPoint) {
        let p = normalized(point)
        sink?.send(.move(x: p.x, y: p.y))
    }

    private func normalized(_ point: CGPoint) -> (x: Double, y: Double) {
        let size = videoSize()
        let rect = size.width > 0 && size.height > 0 ? AVMakeRect(aspectRatio: size, insideRect: bounds) : bounds
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        return (Double(x), Double(y))
    }
}

final class RemoteDisplayViewController: UIViewController {
    private let remoteView: RemoteDisplayView
    private weak var sink: RemoteInputSink?

    init(displayLayer: AVSampleBufferDisplayLayer, sink: RemoteInputSink, videoSize: @escaping () -> CGSize) {
        remoteView = RemoteDisplayView(displayLayer: displayLayer, videoSize: videoSize)
        self.sink = sink
        super.init(nibName: nil, bundle: nil)
        remoteView.sink = sink
        remoteView.onInteraction = { [weak self] in
            guard let self, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = remoteView }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // MARK: - Hardware keyboard (HID usage 그대로 전달)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = forward(presses, down: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = forward(presses, down: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = forward(presses, down: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func forward(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key {
                sink?.send(.key(usage: key.keyCode.rawValue, down: down))
            } else {
                unhandled.insert(press)
            }
        }
        return unhandled
    }
}
