import AppKit
import CoreGraphics

/// iPad 입력을 CGEvent로 주입. 모든 메서드는 `queue`(연결 큐)에서 호출되어야 한다.
/// 손쉬운 사용(Accessibility) 권한 필요.
final class InputInjector {
    private let queue: DispatchQueue
    private let source = CGEventSource(stateID: .hidSystemState)
    private let doubleClickInterval = NSEvent.doubleClickInterval
    private let keyRepeatDelay = NSEvent.keyRepeatDelay
    private let keyRepeatInterval = NSEvent.keyRepeatInterval

    private var displayID: CGDirectDisplayID = 0
    private var location = CGPoint.zero
    private var pressedButtons = Set<MouseButton>()
    private var lastDown: (time: TimeInterval, point: CGPoint, button: MouseButton, count: Int)?
    private var modifierUsages = Set<Int>()
    private var capsLock = false
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var repeatTimer: DispatchSourceTimer?
    private var repeatingUsage: Int?

    init(queue: DispatchQueue) {
        self.queue = queue
        source?.localEventsSuppressionInterval = 0
    }

    func setDisplay(_ id: CGDirectDisplayID) {
        queue.async { self.displayID = id }
    }

    func handle(_ event: InputEvent) {
        switch event {
        case let .move(x, y):
            move(to: point(x, y))
        case let .button(button, down, x, y):
            location = point(x, y)
            mouseButton(button, down: down)
        case let .scroll(dx, dy, phase):
            scroll(dx: dx, dy: dy, phase: phase)
        case let .key(usage, down):
            key(usage: usage, down: down)
        case .releaseAll:
            releaseAll()
        }
    }

    func releaseAll() {
        stopRepeat()
        for button in pressedButtons { mouseButton(button, down: false) }
        for usage in modifierUsages { key(usage: usage, down: false) }
        pressedButtons.removeAll()
        modifierUsages.removeAll()
    }

    // MARK: - Mouse

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID == 0 ? CGMainDisplayID() : displayID)
        let nx = min(max(x, 0), 1), ny = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + nx * (bounds.width - 1), y: bounds.minY + ny * (bounds.height - 1))
    }

    private func move(to p: CGPoint) {
        location = p
        var type: CGEventType
        var button: CGMouseButton
        if pressedButtons.contains(.left) {
            (type, button) = (.leftMouseDragged, .left)
        } else if pressedButtons.contains(.right) {
            (type, button) = (.rightMouseDragged, .right)
        } else if pressedButtons.contains(.middle) {
            (type, button) = (.otherMouseDragged, .center)
        } else {
            (type, button) = (.mouseMoved, .left)
        }
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button))
    }

    private func mouseButton(_ button: MouseButton, down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        var clickCount = 1
        if down {
            if let last = lastDown, last.button == button, now - last.time < doubleClickInterval,
               hypot(last.point.x - location.x, last.point.y - location.y) < 8 {
                clickCount = last.count + 1
            }
            lastDown = (now, location, button, clickCount)
            pressedButtons.insert(button)
        } else {
            clickCount = lastDown?.count ?? 1
            pressedButtons.remove(button)
        }

        var type: CGEventType
        var cgButton: CGMouseButton
        switch button {
        case .left: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    private func scroll(dx: Double, dy: Double, phase: ScrollPhase) {
        // 정수 픽셀 단위로만 보낼 수 있으므로 소수점 이하를 누적
        let tx = dx + scrollRemainder.x, ty = dy + scrollRemainder.y
        let ix = Int32(tx.rounded(.towardZero)), iy = Int32(ty.rounded(.towardZero))
        scrollRemainder = (tx - Double(ix), ty - Double(iy))

        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        var scrollPhase: Int64, momentumPhase: Int64
        switch phase {
        case .began: (scrollPhase, momentumPhase) = (1, 0)          // kCGScrollPhaseBegan
        case .changed: (scrollPhase, momentumPhase) = (2, 0)        // kCGScrollPhaseChanged
        case .ended: (scrollPhase, momentumPhase) = (4, 0)          // kCGScrollPhaseEnded
        case .momentumBegan: (scrollPhase, momentumPhase) = (0, 1)  // kCGMomentumScrollPhaseBegin
        case .momentum: (scrollPhase, momentumPhase) = (0, 2)       // kCGMomentumScrollPhaseContinue
        case .momentumEnded: (scrollPhase, momentumPhase) = (0, 3)  // kCGMomentumScrollPhaseEnd
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // kCGScrollWheelEventScrollPhase(99), kCGScrollWheelEventMomentumPhase(123)
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: scrollPhase)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentumPhase)
        event.location = location
        post(event)
        if phase == .ended || phase == .momentumEnded { scrollRemainder = (0, 0) }
    }

    // MARK: - Keyboard

    private func key(usage: Int, down: Bool) {
        let isModifier = KeyCodeMap.isModifier(usage)
        let isCapsLock = usage == KeyCodeMap.capsLockUsage
        if isModifier {
            if down { modifierUsages.insert(usage) } else { modifierUsages.remove(usage) }
        }
        if isCapsLock, down { capsLock.toggle() }
        guard let keyCode = KeyCodeMap.macKeyCode(forHIDUsage: usage) else { return }

        postKey(keyCode, down: down, flagsChanged: isModifier || isCapsLock, autorepeat: false)

        guard !isModifier, !isCapsLock else { return }
        if down {
            startRepeat(usage: usage, keyCode: keyCode)
        } else if repeatingUsage == usage {
            stopRepeat()
        }
    }

    private func postKey(_ keyCode: CGKeyCode, down: Bool, flagsChanged: Bool, autorepeat: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        if flagsChanged { event.type = .flagsChanged }
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        // 화살표/기능키에 시스템이 붙여주는 Fn·NumericPad 비트는 유지
        event.flags = currentFlags.union(event.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
        event.post(tap: .cghidEventTap)
    }

    /// 주입 이벤트에는 하드웨어 키 반복이 생기지 않으므로 직접 반복한다.
    private func startRepeat(usage: Int, keyCode: CGKeyCode) {
        stopRepeat()
        repeatingUsage = usage
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + keyRepeatDelay, repeating: keyRepeatInterval)
        timer.setEventHandler { [weak self] in
            self?.postKey(keyCode, down: true, flagsChanged: false, autorepeat: true)
        }
        timer.resume()
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.cancel()
        repeatTimer = nil
        repeatingUsage = nil
    }

    private var currentFlags: CGEventFlags {
        var flags: CGEventFlags = []
        for usage in modifierUsages {
            switch usage {
            case 0xE0, 0xE4: flags.insert(.maskControl)
            case 0xE1, 0xE5: flags.insert(.maskShift)
            case 0xE2, 0xE6: flags.insert(.maskAlternate)
            case 0xE3, 0xE7: flags.insert(.maskCommand)
            default: break
            }
        }
        if capsLock { flags.insert(.maskAlphaShift) }
        return flags
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)
    }
}
