import UIKit
import SwiftUI
import AVFoundation
import CoreMedia

enum InputMode: String {
    case trackpad
    case direct

    var label: String { self == .trackpad ? "Trackpad" : "Direct" }
    var symbol: String { self == .trackpad ? "hand.draw" : "cursorarrow.rays" }
}

/// Bridges decoded frames from the session into the rendering view without
/// pushing pixel buffers through SwiftUI's diffing.
final class FrameSink {
    weak var surface: StreamSurface?

    func present(_ sample: CMSampleBuffer) {
        surface?.present(sample)
    }
}

/// UIKit view that draws decoded frames and turns touches into host input.
final class StreamSurface: UIView {

    private let displayLayer = AVSampleBufferDisplayLayer()

    var videoSize: CGSize = .zero {
        didSet { setNeedsLayout() }
    }

    var mode: InputMode = .trackpad {
        didSet { resetGestureState() }
    }

    var onInput: ((InputEvent) -> Void)?
    var onViewport: ((Viewport, Bool) -> Void)?

    /// Currently streamed region. Pinching derives a new one from this.
    var viewport: Viewport = .full

    /// Multiplier applied to finger deltas in trackpad mode.
    private let sensitivity: CGFloat = 1.7
    private let scrollSensitivity: CGFloat = 1.4
    private let dragThreshold: CGFloat = 8
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var lastPoint: CGPoint = .zero
    private var startPoint: CGPoint = .zero
    private var startTime = Date()
    private var hasMoved = false
    private var buttonDown = false
    private var twoFinger = false
    private var scrollCentroid: CGPoint = .zero
    private var scrollMoved = false
    private var longPressWork: DispatchWorkItem?

    private var pinchStart: Viewport = .full
    private var pinchLast: Viewport = .full
    private var pinchActive = false
    private var pinchBeganAt = Date()
    private var pinchCommitted = false
    private weak var pinchRecognizer: UIPinchGestureRecognizer?

    private var threeFingerActive = false
    private var threeFingerStart: CGPoint = .zero
    private var threeFingerFired = false

    /// Highest simultaneous touch count seen in the current gesture. A right
    /// click is only allowed when that is exactly two, so a stray extra finger
    /// can never turn a one-finger tap into a right click.
    private var maxTouches = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
        haptics.prepare()

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        // Must be false: otherwise the recogniser stops delivering touches to
        // this view, so the three-finger detector never sees the third finger.
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)
        pinchRecognizer = pinch

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = true
        addGestureRecognizer(doubleTap)
    }

    // MARK: - Rendering

    func present(_ sample: CMSampleBuffer) {
        // A decode error (or a mid-GOP join) leaves the layer unable to accept
        // samples until it has been flushed.
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        guard displayLayer.status != .failed else { return }
        displayLayer.enqueue(sample)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// Aspect-fit rect for the incoming video inside the view's bounds.
    func videoRect(in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    private func normalised(_ point: CGPoint) -> (Double, Double) {
        let rect = videoRect(in: bounds)
        guard rect.width > 0, rect.height > 0 else { return (0.5, 0.5) }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        return (Double(x), Double(y))
    }

    // MARK: - Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStart = viewport
            pinchLast = viewport
            pinchBeganAt = Date()
            pinchCommitted = false
            // Suppress scrolling straight away, but delay sending a zoom: three
            // fingers land within ~100 ms of each other, and that gesture must
            // not flicker a zoom before it becomes a swipe.
            pinchActive = !threeFingerActive && gesture.numberOfTouches == 2

        case .changed:
            guard !threeFingerActive, gesture.numberOfTouches == 2 else {
                if pinchCommitted {
                    onViewport?(pinchStart, true)
                    pinchCommitted = false
                }
                pinchActive = false
                return
            }
            guard Date().timeIntervalSince(pinchBeganAt) > 0.12 else { return }

            let zoom = min(Viewport.maxZoom, max(1, pinchStart.zoom * gesture.scale))
            let (nx, ny) = normalised(gesture.location(in: self))
            let start = pinchStart.rect
            let anchorX = start.x + nx * start.w
            let anchorY = start.y + ny * start.h
            let side = 1 / zoom
            let next = Viewport(centerX: anchorX + (0.5 - nx) * side,
                                centerY: anchorY + (0.5 - ny) * side,
                                zoom: zoom).clamped
            pinchLast = next
            pinchCommitted = true
            pinchActive = true
            onViewport?(next, false)

        case .ended:
            if pinchCommitted { onViewport?(pinchLast, true) }
            pinchCommitted = false
            pinchActive = false

        case .cancelled, .failed:
            if pinchCommitted { onViewport?(pinchStart, true) }
            pinchCommitted = false
            pinchActive = false

        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if viewport.zoom > 1.01 {
            onViewport?(.full, true)
        } else {
            let (nx, ny) = normalised(gesture.location(in: self))
            onViewport?(Viewport(centerX: nx, centerY: ny, zoom: 2).clamped, true)
        }
        haptics.impactOccurred()
    }

    // MARK: - Touch handling

    private func resetGestureState() {
        longPressWork?.cancel()
        longPressWork = nil
        if buttonDown {
            onInput?(.button(button: 0, down: false))
            buttonDown = false
        }
        hasMoved = false
        twoFinger = false
        scrollMoved = false
        maxTouches = 0
    }

    private func centroid(_ touches: Set<UITouch>) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        var sum = CGPoint.zero
        for touch in touches { sum.x += touch.location(in: self).x; sum.y += touch.location(in: self).y }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }

    private func gestureIsOver(_ event: UIEvent?) -> Bool {
        let stillDown = event?.allTouches?.contains {
            $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
        } ?? false
        return !stillDown
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let all = event?.allTouches else { return }
        maxTouches = max(maxTouches, all.count)
        haptics.prepare()

        if all.count >= 3 {
            longPressWork?.cancel()
            longPressWork = nil
            if !threeFingerActive {
                threeFingerActive = true
                threeFingerStart = centroid(all)
                threeFingerFired = false
                pinchActive = false
                pinchRecognizer?.isEnabled = false
            }
            twoFinger = false
            hasMoved = true
            if buttonDown {
                onInput?(.button(button: 0, down: false))
                buttonDown = false
            }
            return
        }

        if all.count >= 2 {
            longPressWork?.cancel()
            longPressWork = nil
            twoFinger = true
            hasMoved = true
            scrollCentroid = centroid(all)
            scrollMoved = false
            if buttonDown {
                onInput?(.button(button: 0, down: false))
                buttonDown = false
            }
            return
        }

        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        lastPoint = point
        startPoint = point
        startTime = Date()
        hasMoved = false
        twoFinger = false

        if mode == .direct {
            let (nx, ny) = normalised(point)
            onInput?(.moveAbsolute(x: nx, y: ny))
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasMoved, !self.twoFinger, !self.buttonDown else { return }
            self.buttonDown = true
            self.onInput?(.button(button: 0, down: true))
            self.haptics.impactOccurred()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let all = event?.allTouches else { return }

        if threeFingerActive {
            maxTouches = max(maxTouches, all.count)
            guard !threeFingerFired else { return }
            let now = centroid(all)
            let dx = now.x - threeFingerStart.x
            let dy = now.y - threeFingerStart.y
            guard hypot(dx, dy) > 55 else { return }

            threeFingerFired = true
            if abs(dx) > abs(dy) {
                onInput?(.chord(code: dx > 0 ? VirtualKey.rightArrow : VirtualKey.leftArrow,
                                flags: EventFlags.control))
            } else if dy < 0 {
                onInput?(.hostAction("missionControl"))
            } else {
                onInput?(.chord(code: VirtualKey.letter("m") ?? 46, flags: EventFlags.command))
            }
            haptics.impactOccurred()
            return
        }

        guard !pinchActive else { return }
        maxTouches = max(maxTouches, all.count)

        if twoFinger || all.count >= 2 {
            let now = centroid(all)
            let dx = now.x - scrollCentroid.x
            let dy = now.y - scrollCentroid.y
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                scrollMoved = true
                onInput?(.scroll(dx: Int(-dx * scrollSensitivity), dy: Int(-dy * scrollSensitivity)))
                scrollCentroid = now
            }
            return
        }

        guard let touch = touches.first else { return }
        let point = touch.location(in: self)

        if hypot(point.x - startPoint.x, point.y - startPoint.y) > dragThreshold {
            if !hasMoved { longPressWork?.cancel() }
            hasMoved = true
        }

        if mode == .direct {
            let (nx, ny) = normalised(point)
            if buttonDown {
                onInput?(.moveAbsolute(x: nx, y: ny))
            } else if hasMoved {
                buttonDown = true
                onInput?(.button(button: 0, down: true))
                onInput?(.moveAbsolute(x: nx, y: ny))
                haptics.impactOccurred()
            }
        } else {
            let dx = (point.x - lastPoint.x) * sensitivity
            let dy = (point.y - lastPoint.y) * sensitivity
            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                onInput?(.moveRelative(dx: Double(dx), dy: Double(dy)))
            }
        }
        lastPoint = point
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressWork?.cancel()
        longPressWork = nil

        if threeFingerActive {
            if gestureIsOver(event) {
                threeFingerActive = false
                threeFingerFired = false
                pinchRecognizer?.isEnabled = true
                maxTouches = 0
            }
            return
        }

        if pinchActive {
            pinchActive = false
            buttonDown = false
            twoFinger = false
            hasMoved = false
            scrollMoved = false
            maxTouches = 0
            return
        }

        if twoFinger {
            // Right click only for a genuine two-finger tap.
            if !scrollMoved && maxTouches == 2 && gestureIsOver(event) {
                onInput?(.button(button: 1, down: true))
                onInput?(.button(button: 1, down: false))
                haptics.impactOccurred()
            }
            twoFinger = false
            scrollMoved = false
            maxTouches = 0
            return
        }

        if buttonDown {
            onInput?(.button(button: 0, down: false))
            buttonDown = false
            maxTouches = 0
            return
        }

        let duration = Date().timeIntervalSince(startTime)
        if !hasMoved && duration < 0.38 {
            switch mode {
            case .trackpad:
                onInput?(.click(x: nil, y: nil))
            case .direct:
                if let touch = touches.first {
                    let (nx, ny) = normalised(touch.location(in: self))
                    onInput?(.click(x: nx, y: ny))
                }
            }
            haptics.impactOccurred()
        }
        hasMoved = false
        maxTouches = 0
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressWork?.cancel()
        longPressWork = nil
        if buttonDown {
            onInput?(.button(button: 0, down: false))
            buttonDown = false
        }
        pinchActive = false
        threeFingerActive = false
        threeFingerFired = false
        pinchRecognizer?.isEnabled = true
        twoFinger = false
        hasMoved = false
        scrollMoved = false
        maxTouches = 0
    }
}

/// SwiftUI wrapper.
struct VideoSurface: UIViewRepresentable {
    let session: ClientSession
    let videoSize: CGSize
    @Binding var mode: InputMode
    let viewport: Viewport
    let onViewport: (Viewport, Bool) -> Void
    let onInput: (InputEvent) -> Void

    func makeUIView(context: Context) -> StreamSurface {
        let view = StreamSurface()
        view.onInput = onInput
        view.onViewport = onViewport
        view.mode = mode
        view.videoSize = videoSize
        view.viewport = viewport
        session.renderer.surface = view
        return view
    }

    func updateUIView(_ view: StreamSurface, context: Context) {
        view.onInput = onInput
        view.onViewport = onViewport
        view.mode = mode
        view.videoSize = videoSize
        view.viewport = viewport
        session.renderer.surface = view
    }
}
