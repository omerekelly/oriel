import UIKit
import SwiftUI

/// Game-controller style pad for the letterbox area: a left stick that moves the
/// cursor proportionally to deflection, press-and-hold click buttons, and a
/// scroll strip.
///
/// Implemented in UIKit rather than SwiftUI because it needs a 60 Hz tick while
/// the stick is held, and the session view re-renders at frame rate.
final class AnalogPadView: UIView {

    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onButton: ((Int, Bool) -> Void)?

    private let stickBase = UIView()
    private let stickKnob = UIView()
    private let leftButton = UIView()
    private let rightButton = UIView()
    private let scrollPad = UIView()
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()
    private let upChevron = UIImageView(image: UIImage(systemName: "chevron.up"))
    private let downChevron = UIImageView(image: UIImage(systemName: "chevron.down"))

    private enum Zone { case stick, click, right, scroll }
    private var activeZone: Zone?

    private var stickVector = CGPoint.zero
    private var lastScrollY: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    private let stickSize: CGFloat = 148
    private let knobSize: CGFloat = 62
    private let buttonSize: CGFloat = 72
    private let scrollWidth: CGFloat = 54
    private let gap: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        link?.invalidate()
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        stickBase.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        stickBase.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        stickBase.layer.borderWidth = 1

        stickKnob.backgroundColor = UIColor(red: 0.949, green: 0.710, blue: 0.267, alpha: 0.85)
        stickKnob.layer.shadowColor = UIColor.black.cgColor
        stickKnob.layer.shadowOpacity = 0.35
        stickKnob.layer.shadowRadius = 6
        stickKnob.layer.shadowOffset = CGSize(width: 0, height: 2)

        for button in [leftButton, rightButton] {
            button.backgroundColor = UIColor.white.withAlphaComponent(0.10)
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
            button.layer.borderWidth = 1
        }

        leftLabel.text = "L"
        rightLabel.text = "R"
        for label in [leftLabel, rightLabel] {
            label.textAlignment = .center
            label.textColor = .white
            label.font = .systemFont(ofSize: 22, weight: .semibold)
        }

        scrollPad.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        scrollPad.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        scrollPad.layer.borderWidth = 1
        for chevron in [upChevron, downChevron] {
            chevron.tintColor = UIColor.white.withAlphaComponent(0.45)
            chevron.contentMode = .scaleAspectFit
        }

        for view in [stickBase, stickKnob, leftButton, rightButton, scrollPad] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        leftButton.addSubview(leftLabel)
        rightButton.addSubview(rightLabel)
        scrollPad.addSubview(upChevron)
        scrollPad.addSubview(downChevron)

        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let height = bounds.height
        let stickOrigin = CGPoint(x: 0, y: (height - stickSize) / 2)

        stickBase.frame = CGRect(origin: stickOrigin, size: CGSize(width: stickSize, height: stickSize))
        stickBase.layer.cornerRadius = stickSize / 2
        stickKnob.layer.cornerRadius = knobSize / 2
        stickKnob.frame = CGRect(x: stickBase.frame.midX - knobSize / 2,
                                 y: stickBase.frame.midY - knobSize / 2,
                                 width: knobSize, height: knobSize)

        let buttonX = stickBase.frame.maxX + gap
        leftButton.frame = CGRect(x: buttonX,
                                  y: stickBase.frame.midY - buttonSize - 4,
                                  width: buttonSize, height: buttonSize)
        rightButton.frame = CGRect(x: buttonX,
                                   y: stickBase.frame.midY + 4,
                                   width: buttonSize, height: buttonSize)
        leftButton.layer.cornerRadius = buttonSize / 2
        rightButton.layer.cornerRadius = buttonSize / 2
        leftLabel.frame = leftButton.bounds
        rightLabel.frame = rightButton.bounds

        scrollPad.frame = CGRect(x: leftButton.frame.maxX + gap,
                                 y: stickBase.frame.minY,
                                 width: scrollWidth, height: stickSize)
        scrollPad.layer.cornerRadius = 16
        upChevron.frame = CGRect(x: (scrollWidth - 18) / 2, y: 10, width: 18, height: 18)
        downChevron.frame = CGRect(x: (scrollWidth - 18) / 2,
                                   y: scrollPad.bounds.height - 28, width: 18, height: 18)
    }

    // MARK: - Touches

    private func zone(at point: CGPoint) -> Zone? {
        if stickBase.frame.contains(point) { return .stick }
        if leftButton.frame.contains(point) { return .click }
        if rightButton.frame.contains(point) { return .right }
        if scrollPad.frame.contains(point) { return .scroll }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        guard let zone = zone(at: point) else { return }

        activeZone = zone
        switch zone {
        case .stick:
            lastTick = CACurrentMediaTime()
            stickVector = .zero
            updateKnob()
        case .click:
            leftButton.backgroundColor = UIColor(red: 0.949, green: 0.710, blue: 0.267, alpha: 0.55)
            onButton?(0, true)
        case .right:
            rightButton.backgroundColor = UIColor(red: 0.949, green: 0.710, blue: 0.267, alpha: 0.55)
            onButton?(1, true)
        case .scroll:
            lastScrollY = point.y
            scrollPad.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let zone = activeZone, let touch = touches.first else { return }
        let point = touch.location(in: self)

        switch zone {
        case .stick:
            let radius = stickSize / 2 - knobSize / 2
            var vector = CGPoint(x: point.x - stickBase.frame.midX,
                                 y: point.y - stickBase.frame.midY)
            let distance = hypot(vector.x, vector.y)
            if distance > radius, distance > 0 {
                vector = CGPoint(x: vector.x / distance * radius,
                                 y: vector.y / distance * radius)
            }
            stickVector = vector
            updateKnob()

        case .scroll:
            let delta = point.y - lastScrollY
            lastScrollY = point.y
            let amount = Int(-delta / 4)
            if amount != 0 { onScroll?(amount) }

        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch()
    }

    private func finishTouch() {
        switch activeZone {
        case .click:
            leftButton.backgroundColor = UIColor.white.withAlphaComponent(0.10)
            onButton?(0, false)
        case .right:
            rightButton.backgroundColor = UIColor.white.withAlphaComponent(0.10)
            onButton?(1, false)
        case .scroll:
            scrollPad.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        case .stick:
            stickVector = .zero
            updateKnob()
        case .none:
            break
        }
        activeZone = nil
    }

    private func updateKnob() {
        UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.stickKnob.center = CGPoint(x: self.stickBase.bounds.midX + self.stickVector.x,
                                            y: self.stickBase.bounds.midY + self.stickVector.y)
        }
    }

    // MARK: - Movement

    @objc private func step() {
        guard activeZone == .stick else { return }

        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastTick)
        lastTick = now

        let radius = stickSize / 2 - knobSize / 2
        let distance = hypot(stickVector.x, stickVector.y)
        guard distance > 4 else { return }

        let magnitude = min(1, distance / radius)
        let deadZone: CGFloat = 0.12
        guard magnitude > deadZone else { return }

        // Squared response: fine control near the centre, fast at full throw.
        let curve = pow((magnitude - deadZone) / (1 - deadZone), 1.5)
        let speed: CGFloat = 1250
        let dx = stickVector.x / distance * speed * curve * CGFloat(dt)
        let dy = stickVector.y / distance * speed * curve * CGFloat(dt)
        onMove?(dx, dy)
    }
}

struct AnalogPad: UIViewRepresentable {
    let onInput: (InputEvent) -> Void

    func makeUIView(context: Context) -> AnalogPadView {
        let view = AnalogPadView()
        bind(view)
        return view
    }

    func updateUIView(_ view: AnalogPadView, context: Context) {
        bind(view)
    }

    private func bind(_ view: AnalogPadView) {
        view.onMove = { dx, dy in
            onInput(.moveRelative(dx: Double(dx), dy: Double(dy)))
        }
        view.onScroll = { amount in
            onInput(.scroll(dx: 0, dy: amount))
        }
        view.onButton = { index, down in
            onInput(.button(button: index, down: down))
        }
    }
}
