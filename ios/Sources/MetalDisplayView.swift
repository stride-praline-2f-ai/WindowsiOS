// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import QuartzCore
import SwiftUI
import UIKit

final class MetalCanvasUIView: UIView, UIKeyInput {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var trackpadMode: Bool = false {
        didSet {
            guard trackpadMode != oldValue else { return }
            if trackpadMode {
                setNeedsLayout() // the first-time hint shows from layoutSubviews, once the view has a size
            } else {
                stopGlide()
                endHold()
            }
        }
    }
    var rightClickArmed: Bool = false
    var onRightClickConsumed: (() -> Void)?
    var onThreeFingerTap: (() -> Void)?

    private var activeDragButtons: UInt8 = 0
    /// Buttons held by a trackpad or mouse (indirect pointer touches), which go to Windows without gestures.
    private var pointerButtons: UInt8 = 0
    private var panLastPoint: CGPoint = .zero
    private var scrollAccum: CGFloat = 0
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    /// Trackpad mode, as in UTM: a held press drags with the left button, and a flick glides on.
    private var dragLastPoint: CGPoint = .zero
    private var dragHeld = false
    private var glideVelocity: CGPoint = .zero
    private var glideLastTime: CFTimeInterval = 0
    private var glideLink: CADisplayLink?
    /// The finger trackpad moves the pointer this much faster than the laptop deck's, which felt
    /// sluggish over a whole screen.
    private let trackpadBoost: Double = 1.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect
        updateDrawableScale()

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeFingerTap)

        let dragPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        dragPan.minimumNumberOfTouches = 1
        dragPan.maximumNumberOfTouches = 1
        addGestureRecognizer(dragPan)

        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        if #available(iOS 13.4, *) {
            scrollPan.allowedScrollTypesMask = .all
        }
        addGestureRecognizer(scrollPan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        // Half a second held still (8 pt), as in UTM: a finger that hesitates before moving stays a
        // pointer move.
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 8
        addGestureRecognizer(longPress)

        if #available(iOS 13.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hover)
        }

        // Windows draws its own pointer where the iPad's would be (absolute tablet), so the iPad's
        // pointer is hidden over the screen instead of sitting on top of it.
        addInteraction(UIPointerInteraction(delegate: self))

        // The tap, drag and press gestures are for fingers only. A trackpad or mouse button goes straight
        // to Windows (touchesBegan below): through the pan gesture it pressed only after the pointer had
        // moved about 10 pt, so window edges could not be grabbed and drags started late. The scroll pan
        // keeps every touch type, so trackpad and mouse-wheel scrolling still reach it.
        let fingers = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        for gr in [singleTap, twoFingerTap, threeFingerTap, dragPan, longPress] as [UIGestureRecognizer] {
            gr.allowedTouchTypes = fingers
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableScale()
        if window != nil {
            WinIOSBridge.shared.bindMetalLayer(metalLayer)
            DispatchQueue.main.async { [weak self] in self?.keepKeyboardFocus() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableScale()
        if trackpadMode && window != nil && bounds.width > 0 { showTrackpadHintOnce() }
    }

    private func updateDrawableScale() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let w = max(1.0, bounds.width * scale)
        let h = max(1.0, bounds.height * scale)
        metalLayer.drawableSize = CGSize(width: w, height: h)
        if let winBounds = window?.bounds.size, winBounds.width > 0 {
            WinIOSBridge.shared.updateScreenSize(winBounds, scale: scale)
        }
    }

    private func normalizedPoint(for pt: CGPoint) -> (Double, Double) {
        let bw = max(1.0, bounds.width)
        let bh = max(1.0, bounds.height)
        let fbW = Double(WinIOSBridge.shared.framebufferWidth)
        let fbH = Double(WinIOSBridge.shared.framebufferHeight)

        var rect = bounds
        if fbW > 0 && fbH > 0 {
            let viewAspect = Double(bw / bh)
            let fbAspect = fbW / fbH
            if viewAspect > fbAspect {
                let fittedW = CGFloat(Double(bh) * fbAspect)
                rect = CGRect(x: (bw - fittedW) * 0.5, y: 0, width: fittedW, height: bh)
            } else {
                let fittedH = CGFloat(Double(bw) / fbAspect)
                rect = CGRect(x: 0, y: (bh - fittedH) * 0.5, width: bw, height: fittedH)
            }
        }
        let nx = min(1.0, max(0.0, Double((pt.x - rect.minX) / max(1.0, rect.width))))
        let ny = min(1.0, max(0.0, Double((pt.y - rect.minY) / max(1.0, rect.height))))
        return (nx, ny)
    }

    private func pointerMask(_ event: UIEvent?) -> UInt8 {
        if rightClickArmed {
            rightClickArmed = false
            onRightClickConsumed?()
            return 2
        }
        if let event, event.buttonMask.contains(.secondary) { return 2 }
        return 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        keepKeyboardFocus()
        guard let t = touches.first(where: { $0.type == .indirectPointer }) else {
            return super.touchesBegan(touches, with: event)
        }
        pointerButtons = pointerMask(event)
        let (nx, ny) = normalizedPoint(for: t.location(in: self))
        PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: pointerButtons)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { $0.type == .indirectPointer }) else {
            return super.touchesMoved(touches, with: event)
        }
        let (nx, ny) = normalizedPoint(for: t.location(in: self))
        PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: pointerButtons)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { $0.type == .indirectPointer }) else {
            return super.touchesEnded(touches, with: event)
        }
        pointerButtons = 0
        let (nx, ny) = normalizedPoint(for: t.location(in: self))
        PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.contains(where: { $0.type == .indirectPointer }) else {
            return super.touchesCancelled(touches, with: event)
        }
        pointerButtons = 0
        let pc = PointerController.shared
        pc.moveAbsolute(x: pc.cursorX, y: pc.cursorY, extraButtons: 0)
    }

    @objc private func handleSingleTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        stopGlide()
        tapHaptic.impactOccurred(intensity: 0.45)
        let mask: UInt8
        if rightClickArmed {
            rightClickArmed = false
            onRightClickConsumed?()
            mask = 2
        } else {
            mask = 1
        }
        if trackpadMode {
            PointerController.shared.clickAtCurrent(buttonMask: mask)
        } else {
            let (nx, ny) = normalizedPoint(for: gr.location(in: self))
            PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: mask)
        }
    }

    @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.6)
        PointerController.shared.clickAtCurrent(buttonMask: 2)
    }

    @objc private func handleThreeFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onThreeFingerTap?()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        // A held drag ends with the gesture, or when trackpad mode is switched off in the middle of it.
        let over = gr.state == .ended || gr.state == .cancelled || gr.state == .failed
        if dragHeld && (!trackpadMode || over) {
            endHold()
            return
        }
        if trackpadMode {
            // As UTM's trackpad: hold, then move = a left-button drag (files, windows, a selection).
            // Right click stays a two-finger tap.
            let loc = gr.location(in: self)
            switch gr.state {
            case .began:
                stopGlide()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dragLastPoint = loc
                dragHeld = true
                PointerController.shared.setHeldButton(1, down: true)
                showPressRing(at: loc)
            case .changed:
                guard dragHeld else { return }
                PointerController.shared.moveRelative(
                    dxPoints: loc.x - dragLastPoint.x, dyPoints: loc.y - dragLastPoint.y,
                    padWidth: bounds.width, padHeight: bounds.height, boost: trackpadBoost)
                dragLastPoint = loc
            default:
                break
            }
            return
        }
        guard gr.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let (nx, ny) = normalizedPoint(for: gr.location(in: self))
        PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
    }

    private func endHold() {
        guard dragHeld else { return }
        dragHeld = false
        PointerController.shared.setHeldButton(1, down: false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
    }

    private func showPressRing(at point: CGPoint) {
        let ring = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        ring.center = point
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = 32
        ring.layer.borderWidth = 3
        ring.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        addSubview(ring)
        UIView.animate(withDuration: 0.45, delay: 0.1, options: [.curveEaseOut]) {
            ring.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            ring.alpha = 0
        } completion: { _ in ring.removeFromSuperview() }
    }

    private func startGlide(_ velocity: CGPoint) {
        stopGlide()
        guard hypot(velocity.x, velocity.y) > 350 else { return }
        glideVelocity = velocity
        glideLastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(glideStep))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    @objc private func glideStep() {
        let now = CACurrentMediaTime()
        let dt = now - glideLastTime
        glideLastTime = now
        let decay = exp(-dt / 0.11)
        glideVelocity = CGPoint(x: glideVelocity.x * decay, y: glideVelocity.y * decay)
        if hypot(glideVelocity.x, glideVelocity.y) < 40 { stopGlide(); return }
        PointerController.shared.moveRelative(
            dxPoints: glideVelocity.x * dt, dyPoints: glideVelocity.y * dt,
            padWidth: bounds.width, padHeight: bounds.height, boost: trackpadBoost)
    }

    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
    }

    /// The trackpad's gestures cannot be seen, so they are shown once, the first time trackpad mode
    /// appears on a laid-out screen.
    private func showTrackpadHintOnce() {
        let key = "winios.trackpadHintShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let label = UILabel()
        label.text = [
            "Trackpad mode",
            "One finger moves the pointer · tap = click · hold ½ s, then move = drag",
            "Two-finger tap = right click · two-finger swipe = scroll",
            "(Trackpad / Touch in the toolbar switches)",
        ].joined(separator: "\n")
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        label.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        let width = min(bounds.width - 24, 420)
        let size = label.sizeThatFits(CGSize(width: width - 24, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: (bounds.width - width) / 2, y: 16, width: width, height: size.height + 24)
        addSubview(label)
        UserDefaults.standard.set(true, forKey: key)
        UIView.animate(withDuration: 0.5, delay: 8, options: []) {
            label.alpha = 0
        } completion: { _ in label.removeFromSuperview() }
    }

    @objc private func handleOneFingerPan(_ gr: UIPanGestureRecognizer) {
        let loc = gr.location(in: self)
        switch gr.state {
        case .began:
            panLastPoint = loc
            stopGlide()
            if !trackpadMode {
                let (nx, ny) = normalizedPoint(for: loc)
                activeDragButtons = rightClickArmed ? 2 : 1
                if rightClickArmed {
                    rightClickArmed = false
                    onRightClickConsumed?()
                }
                PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons)
            }
        case .changed:
            if trackpadMode {
                let dx = loc.x - panLastPoint.x
                let dy = loc.y - panLastPoint.y
                panLastPoint = loc
                PointerController.shared.moveRelative(
                    dxPoints: dx,
                    dyPoints: dy,
                    padWidth: bounds.width,
                    padHeight: bounds.height,
                    extraButtons: activeDragButtons,
                    boost: trackpadBoost
                )
            } else {
                let (nx, ny) = normalizedPoint(for: loc)
                PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons)
            }
        case .ended, .cancelled, .failed:
            if trackpadMode && gr.state == .ended { startGlide(gr.velocity(in: self)) }
            if activeDragButtons != 0 {
                activeDragButtons = 0
                PointerController.shared.moveAbsolute(
                    x: PointerController.shared.cursorX,
                    y: PointerController.shared.cursorY,
                    extraButtons: 0
                )
            }
        default:
            break
        }
    }

    @objc private func handleTwoFingerScroll(_ gr: UIPanGestureRecognizer) {
        let trans = gr.translation(in: self)
        if gr.state == .began {
            scrollAccum = 0
        } else if gr.state == .changed {
            let delta = trans.y - scrollAccum
            if abs(delta) >= 12 {
                let steps = Int(delta / 12)
                scrollAccum += CGFloat(steps) * 12
                let clamped = Int8(clamping: max(-8, min(8, steps)))
                PointerController.shared.scroll(steps: clamped)
            }
        }
    }

    @objc private func handleHover(_ gr: UIHoverGestureRecognizer) {
        let (nx, ny) = normalizedPoint(for: gr.location(in: self))
        PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons | pointerButtons)
    }

    // MARK: - Software & Hardware Keyboard (USB HID Page 0x07)

    override var canBecomeFirstResponder: Bool { true }

    // The screen keeps keyboard focus, so a hardware keyboard (Magic Keyboard) always types into Windows.
    // The on-screen keyboard shows only when asked for (Keys); otherwise an empty input view stands in for
    // it and the shortcut bar is cleared. Focus is taken when the view appears, on a touch or click, and
    // when Keys changes, never while something is presented over the app (a sign-in sheet's fields keep it).
    var softKeyboardWanted = false {
        didSet {
            guard softKeyboardWanted != oldValue else { return }
            if isFirstResponder {
                reloadInputViews()
            } else {
                DispatchQueue.main.async { [weak self] in self?.keepKeyboardFocus() }
            }
        }
    }
    private let noSoftKeyboard = UIView(frame: .zero)
    override var inputView: UIView? { softKeyboardWanted ? nil : noSoftKeyboard }
    func keepKeyboardFocus() {
        guard window != nil, !isFirstResponder,
              window?.rootViewController?.presentedViewController == nil else { return }
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        _ = becomeFirstResponder()
    }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        for ch in text {
            sendCharacterAsHID(ch)
        }
    }

    func deleteBackward() {
        WinIOSBridge.shared.tapKeyHid(0x2a) // Backspace
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: true)
                    handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: false)
                    handled = true
                }
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private func sendCharacterAsHID(_ ch: Character) {
        guard let (usage, shift) = Self.asciiToHID(ch) else { return }
        if shift { WinIOSBridge.shared.sendKeyHid(0xe1, down: true) }
        WinIOSBridge.shared.sendKeyHid(usage, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            WinIOSBridge.shared.sendKeyHid(usage, down: false)
            if shift { WinIOSBridge.shared.sendKeyHid(0xe1, down: false) }
        }
    }

    static func asciiToHID(_ ch: Character) -> (UInt8, Bool)? {
        if let ascii = ch.asciiValue {
            switch ascii {
            case 97...122: return (UInt8(0x04 + Int(ascii - 97)), false) // a-z
            case 65...90:  return (UInt8(0x04 + Int(ascii - 65)), true)  // A-Z
            case 49...57:  return (UInt8(0x1e + Int(ascii - 49)), false) // 1-9
            case 48:       return (0x27, false) // 0
            case 10, 13:   return (0x28, false) // Enter
            case 9:        return (0x2b, false) // Tab
            case 32:       return (0x2c, false) // Space
            default: break
            }
        }
        let symbols: [Character: (UInt8, Bool)] = [
            "!": (0x1e, true), "@": (0x1f, true), "#": (0x20, true), "$": (0x21, true),
            "%": (0x22, true), "^": (0x23, true), "&": (0x24, true), "*": (0x25, true),
            "(": (0x26, true), ")": (0x27, true), "-": (0x2d, false), "_": (0x2d, true),
            "=": (0x2e, false), "+": (0x2e, true), "[": (0x2f, false), "{": (0x2f, true),
            "]": (0x30, false), "}": (0x30, true), "\\": (0x31, false), "|": (0x31, true),
            ";": (0x33, false), ":": (0x33, true), "'": (0x34, false), "\"": (0x34, true),
            "`": (0x35, false), "~": (0x35, true), ",": (0x36, false), "<": (0x36, true),
            ".": (0x37, false), ">": (0x37, true), "/": (0x38, false), "?": (0x38, true),
        ]
        return symbols[ch]
    }
}

struct MetalDisplayView: UIViewRepresentable {
    @Binding var trackpadMode: Bool
    @Binding var rightClickArmed: Bool
    @Binding var keyboardVisible: Bool
    var onThreeFingerTap: () -> Void

    func makeUIView(context: Context) -> MetalCanvasUIView {
        let view = MetalCanvasUIView(frame: .zero)
        view.onThreeFingerTap = onThreeFingerTap
        view.onRightClickConsumed = {
            DispatchQueue.main.async { self.rightClickArmed = false }
        }
        return view
    }

    func updateUIView(_ uiView: MetalCanvasUIView, context: Context) {
        uiView.trackpadMode = trackpadMode
        uiView.rightClickArmed = rightClickArmed
        uiView.onThreeFingerTap = onThreeFingerTap
        // Keys only shows or hides the on-screen keyboard; keyboard focus stays on the screen.
        uiView.softKeyboardWanted = keyboardVisible
    }
}

// Hide the iPad pointer over the Windows screen; Windows' own pointer follows it exactly.
extension MetalCanvasUIView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle.hidden()
    }
}
