import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// The ⇧⌘1 sheet over the whole screen. Esc, ⇧⌘1 again, or a click beside
/// the picture puts the screen back.
final class SnapPanel: NSPanel {
    private let view: SnapView
    private let onClose: () -> Void

    init(screen: NSScreen, job: SnapJob, onClose: @escaping () -> Void) {
        view = SnapView(frame: CGRect(origin: .zero, size: screen.frame.size), job: job)
        self.onClose = onClose
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = view
        view.onDismiss = { [weak self] in self?.dismiss() }
        makeKeyAndOrderFront(nil)  // for Esc; a non-activating panel leaves the app in front as it is
        view.play()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    func dismiss() {
        guard !view.closing else { return }
        view.finish { [weak self] in
            self?.orderOut(nil)
            self?.onClose()
        }
    }
}

/// A band of light sweeps across the screen, and behind it the screen
/// springs down into a picture that the GPU takes apart at its rim (see
/// `SnapEffect`). Once it's read, hovering a paragraph inks in its
/// translation; dragging over an area keeps everything in it translated.
final class SnapView: NSView {
    var onDismiss: () -> Void = {}
    private(set) var closing = false
    private let job: SnapJob
    private let shrink: CGFloat = 0.86
    private let corner: CGFloat = 22
    private lazy var bandWidth = bounds.width * 0.3

    private let backdrop = CALayer()
    private var shader: ShaderLayer?
    /// Laid exactly over the picture the shader draws: the translations, the reading scan, the lens.
    private let sheet = CALayer()
    private let scan = CAGradientLayer()
    private let lens = CALayer()
    /// The screen as it was, until the sweep has passed.
    private let before = CALayer()
    private let sweep = CAGradientLayer()
    private let band = CALayer()

    private var started: CFTimeInterval = 0
    private var closedAt: CFTimeInterval?
    private var whenClosed: (() -> Void)?
    private var patches: [Patch] = []
    private var inks: [Int: CALayer] = [:]
    private var hovered: Int?
    private var pinned: Set<Int> = []
    /// Areas dragged over before the translations were in.
    private var waiting: [CGRect] = []
    private var dragStart: CGPoint?
    private var dragging = false
    private var follow: Timer?

    override var isFlipped: Bool { true }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var pictureFrame: CGRect {
        bounds.insetBy(dx: bounds.width * (1 - shrink) / 2, dy: bounds.height * (1 - shrink) / 2)
    }

    init(frame: CGRect, job: SnapJob) {
        self.job = job
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let root = layer!
        let size = frame.size

        // The dark the picture floats in: the screen itself, far out of focus.
        backdrop.frame = bounds
        backdrop.contents = Self.blurred(job.image)
        backdrop.contentsGravity = .resizeAspectFill
        let tint = CALayer()
        tint.frame = bounds
        tint.backgroundColor = CGColor(gray: 0.02, alpha: 0.82)
        backdrop.addSublayer(tint)
        root.addSublayer(backdrop)

        sheet.bounds = bounds
        sheet.position = center
        sheet.transform = CATransform3DMakeScale(shrink, shrink, 1)
        sheet.masksToBounds = true
        sheet.cornerRadius = corner / shrink
        if let shader = ShaderLayer(image: job.image, size: size, effect: .current, band: 56, corner: corner, view: self) {
            shader.frame = bounds
            shader.contentsScale = job.scale
            shader.drawableSize = CGSize(width: size.width * job.scale, height: size.height * job.scale)
            shader.rect = bounds
            shader.onFrame = { [weak self] now in self?.frame(at: now) }
            root.addSublayer(shader)
            self.shader = shader
        } else {
            sheet.contents = job.image  // no Metal: just the picture
            sheet.contentsScale = job.scale
        }
        root.addSublayer(sheet)

        // While the screen is read, a band of light runs down the picture.
        scan.frame = CGRect(x: 0, y: -260, width: size.width, height: 260)
        scan.colors = [NSColor.clear.cgColor, CGColor(srgbRed: 0.4, green: 0.65, blue: 1, alpha: 0.25), NSColor.clear.cgColor]
        scan.compositingFilter = "screenBlendMode"
        scan.opacity = 0
        sheet.addSublayer(scan)

        lens.cornerRadius = 8
        lens.borderWidth = 1.5 / shrink
        lens.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        lens.backgroundColor = CGColor(srgbRed: 0.4, green: 0.65, blue: 1, alpha: 0.07)
        lens.shadowColor = CGColor(srgbRed: 0.4, green: 0.65, blue: 1, alpha: 1)
        lens.shadowRadius = 14
        lens.shadowOpacity = 0.9
        lens.shadowOffset = .zero
        lens.opacity = 0
        sheet.addSublayer(lens)

        before.frame = bounds
        before.contents = job.image
        before.contentsScale = job.scale
        sweep.frame = bounds
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        let edgeAt = -bandWidth / 2 / size.width
        sweep.locations = [NSNumber(value: edgeAt), NSNumber(value: edgeAt + 0.001)]
        before.mask = sweep
        root.addSublayer(before)

        // Glimm's band: its colours shift top to bottom, fall away like a bell
        // side to side, with a brighter core.
        band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: size.height)
        band.compositingFilter = "screenBlendMode"
        let hues = CAGradientLayer()
        hues.frame = band.bounds
        let palette: [UInt32] = [0x3D7BFF, 0x8A5CFF, 0xFF5FA2, 0xFFB259, 0x4FD1FF]
        hues.colors = palette.map { (hex: UInt32) -> CGColor in
            let r = CGFloat(hex >> 16 & 0xFF), g = CGFloat(hex >> 8 & 0xFF), b = CGFloat(hex & 0xFF)
            return CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        }
        hues.mask = Self.bell(band.bounds, tightness: 16, peak: 0.95)
        band.addSublayer(hues)
        let core = CALayer()
        core.frame = band.bounds
        core.backgroundColor = .white
        core.mask = Self.bell(band.bounds, tightness: 110, peak: 0.55)
        band.addSublayer(core)
        root.addSublayer(band)

        let host = NSHostingView(rootView: TranslationHost(job: job))
        host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(host)

        job.onReady = { [weak self] patches in self?.read(patches) }
        job.onFail = { [weak self] in
            NSSound.beep()
            self?.fade(self?.scan, to: 0)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func play() {
        started = CACurrentMediaTime()
        let size = bounds.size
        // Explicit, from and to: the layers were only just made, so there's
        // nothing yet for an implicit animation to start from.
        func move(_ layer: CALayer, _ keyPath: String, from: Any, to: Any) {
            let move = CABasicAnimation(keyPath: keyPath)
            move.fromValue = from
            move.toValue = to
            move.duration = 1.1
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            layer.setValue(to, forKeyPath: keyPath)
            layer.add(move, forKey: keyPath)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.settle() }
        let start = -bandWidth / 2, end = size.width + bandWidth / 2
        move(band, "position.x", from: start, to: end)
        let from = start / size.width, to = end / size.width
        move(sweep, "locations", from: [from, from + 0.001], to: [to, to + 0.001])
        CATransaction.commit()
        if shader == nil {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 1
            spring.toValue = shrink
            spring.damping = 16
            spring.stiffness = 120
            spring.duration = spring.settlingDuration
            sheet.add(spring, forKey: "shrink")
        }
    }

    /// Each display frame: where the picture is and how far along it is.
    private func frame(at now: CFTimeInterval) {
        guard let shader else { return }
        var scale: CGFloat
        if let closedAt {
            let c = min((now - closedAt) / 0.55, 1)
            let eased = c * c * (3 - 2 * c)
            scale = shrink + (1 - shrink) * eased
            shader.intro = Float(1 - eased)
            shader.spawn = Float(1 - eased)
            if c >= 1, let done = whenClosed {
                whenClosed = nil
                shader.invalidate()
                DispatchQueue.main.async(execute: done)
            }
        } else {
            let t = now - started
            // A spring down to the picture's size, with a little overshoot.
            let omega = 11.0, zeta = 0.62, damped = omega * (1 - zeta * zeta).squareRoot()
            let x = 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
            scale = 1 + (shrink - 1) * x
            shader.intro = Float(min(max((t - 0.1) / 1.5, 0), 1))
            // A big echo as it lands, then the steady pulse.
            shader.spawn = Float(min(t / 0.3, 1) + 3 * exp(-pow((t - 0.35) / 0.22, 2)))
        }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        shader.rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        if let window { shader.mouse = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
    }

    /// The sweep has passed: the band fades and the reading begins to show.
    private func settle() {
        guard !closing else { return }
        before.removeFromSuperlayer()
        fade(band, to: 0, duration: 0.25)
        if patches.isEmpty {
            let run = CABasicAnimation(keyPath: "position.y")
            run.fromValue = -130
            run.toValue = bounds.height + 130
            run.duration = 1.8
            run.repeatCount = .infinity
            run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scan.add(run, forKey: "run")
            fade(scan, to: 1)
        }
        // The pointer is followed by its position: a sheet over another app
        // doesn't reliably get mouse-moved events.
        follow = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.track() }
    }

    /// The translations are in: each waits, unseen, over its paragraph.
    private func read(_ patches: [Patch]) {
        self.patches = patches
        for patch in patches {
            let ink = CALayer()
            ink.contents = patch.image
            ink.contentsScale = job.scale
            ink.frame = Self.points(patch.box, job.scale)
            ink.opacity = 0
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.name = "blur"
            blur.setValue(6, forKey: kCIInputRadiusKey)
            ink.filters = [blur]
            sheet.insertSublayer(ink, below: scan)
            inks[patch.id] = ink
        }
        fade(scan, to: 0, duration: 0.5)
        for area in waiting { pin(in: area) }
        waiting = []
        hovered = nil
    }

    private func track() {
        guard !closing, !dragging, let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let id = patch(at: point)?.id
        guard id != hovered else { return }
        if let old = hovered, !pinned.contains(old) { ink(old, in: false) }
        hovered = id
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if let id, let box = patches.first(where: { $0.id == id })?.box {
            lens.frame = Self.points(box, job.scale).insetBy(dx: -6, dy: -6)
            lens.opacity = 1
            ink(id, in: true)
        } else {
            lens.opacity = 0
        }
        CATransaction.commit()
    }

    /// Ink: the translation settles in out of a blur, or melts back into one.
    private func ink(_ id: Int, in show: Bool) {
        guard let layer = inks[id] else { return }
        let duration = show ? 0.3 : 0.2
        let blur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        blur.fromValue = show ? 6 : 0
        blur.toValue = show ? 0 : 6
        blur.duration = duration
        layer.setValue(show ? 0 : 6, forKeyPath: "filters.blur.inputRadius")
        layer.add(blur, forKey: "blur")
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.opacity = show ? 1 : 0
        layer.transform = show ? CATransform3DIdentity : CATransform3DMakeScale(1.04, 1.04, 1)
        CATransaction.commit()
    }

    /// Everything in a dragged area stays translated, top to bottom.
    private func pin(in area: CGRect) {
        let pixels = CGRect(x: area.minX * job.scale, y: area.minY * job.scale, width: area.width * job.scale, height: area.height * job.scale)
        let caught = patches.filter { $0.box.intersects(pixels) }.sorted { $0.box.minY < $1.box.minY }
        for (i, patch) in caught.enumerated() where !pinned.contains(patch.id) {
            pinned.insert(patch.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { [weak self] in self?.ink(patch.id, in: true) }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, !closing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(point.x - start.x, point.y - start.y) < 4 { return }
        dragging = true
        let a = local(start), b = local(point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // the outline follows the pointer exactly
        lens.frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        lens.opacity = 1
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { dragStart = nil }
        if dragging {
            dragging = false
            let area = lens.frame
            fade(lens, to: 0)
            hovered = nil
            return patches.isEmpty ? waiting.append(area) : pin(in: area)
        }
        guard pictureFrame.contains(point) else { return onDismiss() }
        // A click keeps the paragraph under the pointer translated, or lets it go.
        if let id = hovered {
            if pinned.remove(id) == nil { pinned.insert(id) }
        }
    }

    /// Back to the screen: the translations melt, the rim heals and the
    /// picture grows back to fill it, exactly where everything was.
    func finish(then done: @escaping () -> Void) {
        closing = true
        follow?.invalidate()
        before.removeFromSuperlayer()
        fade(sheet, to: 0, duration: 0.2)
        fade(band, to: 0, duration: 0.2)
        guard shader != nil else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.42)
            CATransaction.setCompletionBlock(done)
            sheet.opacity = 1
            sheet.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }
        whenClosed = done
        closedAt = CACurrentMediaTime()
    }

    private func fade(_ layer: CALayer?, to opacity: Float, duration: Double = 0.3) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer?.opacity = opacity
        CATransaction.commit()
    }

    /// A point on the sheet, in the picture's own (unshrunk) coordinates.
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - center.x) / shrink + center.x, y: (point.y - center.y) / shrink + center.y)
    }

    private func patch(at point: CGPoint) -> Patch? {
        guard pictureFrame.contains(point) else { return nil }
        let p = local(point)
        let pixel = CGPoint(x: p.x * job.scale, y: p.y * job.scale)
        return patches.first { $0.box.insetBy(dx: -4, dy: -4).contains(pixel) }
    }

    private static func points(_ box: CGRect, _ scale: CGFloat) -> CGRect {
        CGRect(x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale)
    }

    /// The screen, small and softly blurred.
    private static func blurred(_ image: CGImage) -> CGImage? {
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1))
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: small.extent)
        return CIContext().createCGImage(soft, from: small.extent)
    }

    /// A mask that's brightest down the middle and falls away like a bell to each side.
    private static func bell(_ bounds: CGRect, tightness: Double, peak: Double) -> CAGradientLayer {
        let mask = CAGradientLayer()
        mask.frame = bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let stops = (0...16).map { Double($0) / 16 }
        mask.locations = stops.map { NSNumber(value: $0) }
        mask.colors = stops.map { NSColor.black.withAlphaComponent(peak * exp(-tightness * ($0 - 0.5) * ($0 - 0.5))).cgColor }
        return mask
    }
}
