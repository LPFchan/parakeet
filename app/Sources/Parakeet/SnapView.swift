import AppKit
import CoreImage
import QuartzCore
import SwiftUI

private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// How the picture is dressed while trying looks out:
/// `defaults write plus.lost.parakeet snapLook glow|fireflies|glass|siri`.
enum SnapLook: String {
    case glow, fireflies, glass, siri
    static var current: SnapLook { SnapLook(rawValue: UserDefaults.standard.string(forKey: "snapLook") ?? "") ?? .glow }

    /// A few colours that belong together, for the sweep, the glow and the sparks.
    var colors: [CGColor] {
        switch self {
        case .glow, .siri: return [rgb(0x3D7BFF), rgb(0x8A5CFF), rgb(0xFF5FA2), rgb(0xFFB259), rgb(0x4FD1FF)]
        case .fireflies: return [rgb(0xFFC46B), rgb(0xFF9F4A), rgb(0xFFE3A3)]
        case .glass: return [rgb(0xFFFFFF), rgb(0xCFE8FF), rgb(0xFFFFFF)]
        }
    }

    /// What the dark around the picture is tinted.
    var shade: CGColor {
        switch self {
        case .glow, .siri: return rgb(0x05060A, 0.72)
        case .fireflies: return rgb(0x070B1C, 0.8)
        case .glass: return rgb(0x0A0C12, 0.45)
        }
    }
}

/// The ⇧⌘1 sheet over the whole screen. Esc, ⇧⌘1 again, or a click beside
/// the picture puts the screen back.
final class SnapPanel: NSPanel {
    private let view: SnapView
    private let onClose: () -> Void

    init(screen: NSScreen, job: SnapJob, onClose: @escaping () -> Void) {
        view = SnapView(frame: CGRect(origin: .zero, size: screen.frame.size), job: job, look: .current)
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

/// A band of light sweeps across the screen, and behind it the screen springs
/// down into a picture whose rim crumbles into dust, drifting off into its own
/// blurred dark. Once it's read, hovering a paragraph inks in its translation;
/// dragging over an area keeps everything in it translated.
final class SnapView: NSView {
    var onDismiss: () -> Void = {}
    private(set) var closing = false
    private let job: SnapJob
    private let look: SnapLook
    private let shrink: CGFloat = 0.86
    private let corner: CGFloat = 22
    /// How far in from its edge the picture crumbles, in points on the sheet.
    private let crumble: CGFloat = 48
    private lazy var bandWidth = bounds.width * 0.3

    private let backdrop = CALayer()
    /// The look's dressing: behind the picture, over it, and drifting in the dark.
    private let under = CALayer()
    private let over = CALayer()
    private let drop = CALayer()
    private let picture = CALayer()
    private var dust: DustLayer?
    private let scan = CAGradientLayer()
    private let lens = CALayer()
    private var emitters: [CAEmitterLayer] = []
    /// The screen as it was, until the sweep has passed.
    private let before = CALayer()
    private let sweep = CAGradientLayer()
    private let band = CALayer()

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

    init(frame: CGRect, job: SnapJob, look: SnapLook) {
        self.job = job
        self.look = look
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let root = layer!
        let size = frame.size

        backdrop.frame = bounds
        backdrop.contents = Self.blurred(job.image, sigma: 6)
        backdrop.contentsGravity = .resizeAspectFill
        let tint = CALayer()
        tint.frame = bounds
        tint.backgroundColor = look.shade
        backdrop.addSublayer(tint)
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.frame = bounds
        vignette.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.55).cgColor]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.05, y: 1.05)
        backdrop.addSublayer(vignette)
        root.addSublayer(backdrop)

        under.frame = bounds
        under.opacity = 0
        root.addSublayer(under)

        // A deep, soft drop, so the picture floats.
        drop.frame = pictureFrame.insetBy(dx: crumble, dy: crumble)
        drop.shadowPath = CGPath(roundedRect: drop.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
        drop.shadowColor = .black
        drop.shadowOpacity = 0.6
        drop.shadowRadius = 48
        drop.shadowOffset = CGSize(width: 0, height: 24)
        drop.opacity = 0
        root.addSublayer(drop)

        picture.bounds = bounds
        picture.position = center
        picture.contents = job.image
        picture.contentsScale = job.scale
        // Its rim, crumbling: the dust below breaks off from these holes.
        let rim = CALayer()
        rim.frame = picture.bounds
        rim.contents = DustLayer.erodedMask(size: bounds.size, band: crumble / shrink, corner: corner / shrink)
        picture.mask = rim
        root.addSublayer(picture)

        // While the screen is read, a band of light runs down the picture.
        scan.frame = CGRect(x: 0, y: -260, width: size.width, height: 260)
        scan.colors = [NSColor.clear.cgColor, look.colors[0].copy(alpha: 0.28)!, look.colors[1].copy(alpha: 0.12)!, NSColor.clear.cgColor]
        scan.compositingFilter = "screenBlendMode"
        scan.opacity = 0
        picture.addSublayer(scan)

        lens.cornerRadius = 8
        lens.borderWidth = 1.5 / shrink
        lens.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        lens.backgroundColor = look.colors[0].copy(alpha: 0.07)
        lens.shadowColor = look.colors[0]
        lens.shadowRadius = 14
        lens.shadowOpacity = 0.9
        lens.shadowOffset = .zero
        lens.opacity = 0
        picture.addSublayer(lens)

        if let dust = DustLayer(image: job.image, imageScale: job.scale, picture: pictureFrame, shrink: shrink, band: crumble, view: self) {
            dust.frame = bounds
            dust.contentsScale = job.scale
            dust.drawableSize = CGSize(width: size.width * job.scale, height: size.height * job.scale)
            root.addSublayer(dust)
            self.dust = dust
        }

        over.frame = bounds
        over.opacity = 0
        root.addSublayer(over)

        dress()

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

        // Glimm's band, in the look's colours: top to bottom they shift, side
        // to side they fall away like a bell, with a brighter core.
        band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: size.height)
        band.compositingFilter = "screenBlendMode"
        let hues = CAGradientLayer()
        hues.frame = band.bounds
        hues.colors = look.colors
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

    /// Each look's glow and particles.
    private func dress() {
        // Glows sit just inside the crumble, so only their light reaches past it.
        let frame = pictureFrame.insetBy(dx: crumble * 0.6, dy: crumble * 0.6)
        switch look {
        case .glow:
            // Light bleeding out from behind the picture, slowly turning and breathing.
            under.addSublayer(rim(frame, width: 0, softness: 80, period: 14, opacity: 1, filled: true))
            under.addSublayer(rim(frame, width: 0, softness: 34, period: -19, opacity: 0.8, filled: true))
            breathe(under, low: 0.7)
        case .siri:
            // Siri's edge: colours that flow along the picture's rim and spill onto it.
            under.addSublayer(rim(frame, width: 0, softness: 60, period: 9, opacity: 0.6, filled: true))
            over.addSublayer(rim(frame, width: 6, softness: 18, period: 7, opacity: 0.9))
            over.addSublayer(rim(frame, width: 6, softness: 18, period: -11, opacity: 0.65, blend: "screenBlendMode"))
            over.addSublayer(rim(frame, width: 2.5, softness: 2, period: 7, opacity: 1, blend: "screenBlendMode"))
            breathe(over, low: 0.8, period: 1.6)
        case .fireflies:
            under.addSublayer(rim(frame, width: 0, softness: 80, period: 30, opacity: 0.5, filled: true))
            breathe(under, low: 0.6, period: 3.5)
            // Three depths: far and sharp, middle, and near, big and out of focus.
            let warm = look.colors
            emit(on: bounds, cells: [
                Self.cell(Self.dot(16, core: 0.4), color: warm[2], birthRate: 26, lifetime: 7, velocity: 4, scale: 0.18) {
                    $0.scaleRange = 0.08; $0.alphaRange = 0.5; $0.alphaSpeed = -0.12; $0.lifetimeRange = 3
                },
                Self.cell(Self.dot(32, core: 0.2), color: warm[0], birthRate: 9, lifetime: 6, velocity: 10, scale: 0.35) {
                    $0.scaleRange = 0.15; $0.alphaSpeed = -0.15; $0.lifetimeRange = 2; $0.velocityRange = 6
                },
                Self.cell(Self.dot(128, core: 0), color: warm[1].copy(alpha: 0.16)!, birthRate: 1.4, lifetime: 9, velocity: 16, scale: 0.9) {
                    $0.scaleRange = 0.4; $0.alphaSpeed = -0.015; $0.velocityRange = 8
                },
            ], prewarm: 6)
        case .glass:
            // A pane of frosted glass the picture rests on, its rim catching the light.
            let paneFrame = pictureFrame.insetBy(dx: -18, dy: -18)
            let pane = CALayer()
            pane.frame = paneFrame
            pane.cornerRadius = corner + 18
            pane.masksToBounds = true
            pane.contents = Self.blurred(job.image, sigma: 3, brighten: 0.12)
            pane.contentsGravity = .resize
            pane.contentsRect = CGRect(x: paneFrame.minX / bounds.width, y: paneFrame.minY / bounds.height,
                                       width: paneFrame.width / bounds.width, height: paneFrame.height / bounds.height)
            let frost = CALayer()
            frost.frame = pane.bounds
            frost.backgroundColor = rgb(0xFFFFFF, 0.08)
            pane.addSublayer(frost)
            under.addSublayer(pane)
            // A thin rim, bright where light falls on it (top left), dim where it doesn't.
            let edge = CAGradientLayer()
            edge.frame = paneFrame
            edge.colors = [rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0.08), rgb(0xFFFFFF, 0.3)]
            edge.startPoint = CGPoint(x: 0, y: 0)
            edge.endPoint = CGPoint(x: 1, y: 1)
            edge.mask = Self.stroke(edge.bounds, corner: corner + 18, width: 1.2, softness: 0)
            under.addSublayer(edge)
            // A glint of light travelling round the rim.
            under.addSublayer(rim(paneFrame, corner: corner + 18, width: 2, softness: 5, period: 6, opacity: 1,
                                  colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.95), rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0)]))
        }
    }

    func play() {
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

        // Behind the band, the screen springs down into a picture.
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1
        spring.toValue = shrink
        spring.damping = 16
        spring.stiffness = 120
        spring.duration = spring.settlingDuration
        picture.transform = CATransform3DMakeScale(shrink, shrink, 1)
        picture.add(spring, forKey: "shrink")
        fade(drop, to: 1, duration: 0.9)
    }

    /// The sweep has passed: the band fades, the rim starts crumbling, the
    /// look comes up, and the reading begins to show.
    private func settle() {
        guard !closing else { return }
        before.removeFromSuperlayer()
        fade(band, to: 0, duration: 0.25)
        fade(under, to: 1, duration: 0.7)
        fade(over, to: 1, duration: 0.7)
        dust?.start()
        for emitter in emitters { emitter.birthRate = 1 }
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
            picture.insertSublayer(ink, below: scan)
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

    /// Back to the screen: the translations melt, the dust settles, and the
    /// picture grows back whole to fill it, exactly where everything was.
    func finish(then done: @escaping () -> Void) {
        closing = true
        follow?.invalidate()
        dust?.stop()
        picture.mask = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        for layer in [lens, scan, under, over, band, drop] + emitters { layer.opacity = 0 }
        for id in inks.keys where inks[id]!.opacity > 0 { ink(id, in: false) }
        CATransaction.commit()
        for emitter in emitters { emitter.birthRate = 0 }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.42)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self] in
            self?.dust?.invalidate()
            done()
        }
        before.removeFromSuperlayer()
        picture.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// A ring of the look's colours turning round a rounded rectangle; `width`
    /// is its solid core and `softness` how far it glows out to either side.
    private func rim(_ frame: CGRect, corner: CGFloat? = nil, width: CGFloat, softness: CGFloat, period: Double, opacity: Float,
                     colors: [CGColor]? = nil, blend: String? = nil, filled: Bool = false) -> CALayer {
        let margin = width / 2 + softness * 2
        let ring = CALayer()
        ring.frame = frame.insetBy(dx: -margin, dy: -margin)
        ring.opacity = opacity
        ring.compositingFilter = blend
        let colours = CAGradientLayer()
        colours.type = .conic
        let side = hypot(ring.bounds.width, ring.bounds.height)
        colours.frame = CGRect(x: ring.bounds.midX - side / 2, y: ring.bounds.midY - side / 2, width: side, height: side)
        let palette = colors ?? look.colors
        colours.colors = palette + [palette[0]]
        colours.startPoint = CGPoint(x: 0.5, y: 0.5)
        colours.endPoint = CGPoint(x: 0.5, y: 0)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = period > 0 ? 2 * Double.pi : -2 * Double.pi
        turn.duration = abs(period)
        turn.repeatCount = .infinity
        colours.add(turn, forKey: "turn")
        ring.addSublayer(colours)
        let mask = Self.stroke(ring.bounds.insetBy(dx: margin, dy: margin), in: ring.bounds, corner: corner ?? self.corner,
                               width: width, softness: softness)
        if filled { mask.fillColor = .black }  // light from the whole area behind, not a line
        ring.mask = mask
        return ring
    }

    /// Slowly brighter and dimmer, on a holder inside the layer so fading the layer itself still works.
    private func breathe(_ layer: CALayer, low: Float, period: Double = 2.8) {
        let holder = CALayer()
        holder.frame = layer.bounds
        for sublayer in layer.sublayers ?? [] { holder.addSublayer(sublayer) }
        layer.addSublayer(holder)
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = low
        breath.duration = period
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        holder.add(breath, forKey: "breathe")
    }

    private func emit(on area: CGRect, cells: [CAEmitterCell], prewarm: Double = 0) {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .surface
        emitter.emitterPosition = CGPoint(x: area.midX, y: area.midY)
        emitter.emitterSize = area.size
        emitter.renderMode = .additive
        emitter.emitterCells = cells
        emitter.birthRate = 0
        if prewarm > 0 { emitter.beginTime = CACurrentMediaTime() - prewarm }
        under.addSublayer(emitter)
        emitters.append(emitter)
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
    private static func blurred(_ image: CGImage, sigma: Double, brighten: Double = 0) -> CGImage? {
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1))
        var soft = small.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: small.extent)
        if brighten > 0 {
            soft = soft.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brighten, kCIInputSaturationKey: 1.2])
        }
        return CIContext().createCGImage(soft, from: small.extent)
    }

    /// A mask tracing a rounded rectangle: solid `width` wide, fading out over `softness`.
    private static func stroke(_ rect: CGRect, in bounds: CGRect? = nil, corner: CGFloat, width: CGFloat, softness: CGFloat) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = bounds ?? rect
        let path = bounds == nil ? rect.insetBy(dx: width / 2, dy: width / 2) : rect
        shape.path = CGPath(roundedRect: path, cornerWidth: corner, cornerHeight: corner, transform: nil)
        shape.fillColor = nil
        shape.strokeColor = .black
        shape.lineWidth = width
        if softness > 0 {
            shape.shadowColor = .black
            shape.shadowOpacity = 1
            shape.shadowRadius = softness
            shape.shadowOffset = .zero
        }
        return shape
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

    private static func cell(_ image: CGImage, color: CGColor, birthRate: Float, lifetime: Float, velocity: CGFloat, scale: CGFloat,
                             _ tune: (CAEmitterCell) -> Void = { _ in }) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.color = color
        cell.birthRate = birthRate
        cell.lifetime = lifetime
        cell.velocity = velocity
        cell.scale = scale
        cell.emissionRange = 2 * .pi
        tune(cell)
        return cell
    }

    /// A soft round dot; `core` is how far out it stays fully bright.
    private static func dot(_ side: Int, core: CGFloat) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor.white, CGColor.white, CGColor(gray: 1, alpha: 0)] as CFArray,
                                  locations: [0, core, 1])!
        let middle = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.drawRadialGradient(gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: CGFloat(side) / 2, options: [])
        return context.makeImage()!
    }
}
