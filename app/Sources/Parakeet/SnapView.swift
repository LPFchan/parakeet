import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// Glimm's "prism": the colours of the sweep, the ring and the sparks.
private let prism: [CGColor] = [
    CGColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1),
    CGColor(srgbRed: 1.00, green: 0.36, blue: 0.75, alpha: 1),
    CGColor(srgbRed: 0.62, green: 0.40, blue: 1.00, alpha: 1),
    CGColor(srgbRed: 0.31, green: 0.52, blue: 1.00, alpha: 1),
    CGColor(srgbRed: 0.20, green: 0.88, blue: 0.90, alpha: 1),
    CGColor(srgbRed: 0.48, green: 1.00, blue: 0.55, alpha: 1),
]

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

/// A band of light sweeps across the screen, and behind it the screen springs
/// down into a picture floating in its own blurred glow, sparks pouring off
/// its edge. Once it's read, hovering a paragraph inks in its translation;
/// dragging over an area keeps everything in it translated.
final class SnapView: NSView {
    var onDismiss: () -> Void = {}
    private(set) var closing = false
    private let job: SnapJob
    private let shrink: CGFloat = 0.84
    private let corner: CGFloat = 18
    private lazy var bandWidth = bounds.width * 0.28

    private let backdrop = CALayer()
    private let motes = CAEmitterLayer()
    private let ring = CALayer()
    private let picture = CALayer()
    private let scan = CAGradientLayer()
    private let lens = CALayer()
    private let sparks = CAEmitterLayer()
    /// The screen as it was, until the sweep has passed.
    private let before = CALayer()
    private let sweep = CAGradientLayer()
    private let band = CALayer()
    private let trail = CAEmitterLayer()

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

        backdrop.frame = bounds
        backdrop.contents = Self.blurred(job.image)
        backdrop.contentsGravity = .resizeAspectFill
        let shade = CAGradientLayer()
        shade.type = .radial
        shade.frame = bounds
        shade.colors = [NSColor.black.withAlphaComponent(0.35), NSColor.black.withAlphaComponent(0.85)].map(\.cgColor)
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 1)
        backdrop.addSublayer(shade)
        root.addSublayer(backdrop)

        // Slow, soft motes of colour drifting in the background, and the odd twinkle.
        motes.frame = bounds
        motes.emitterShape = .rectangle
        motes.emitterMode = .surface
        motes.emitterPosition = center
        motes.emitterSize = size
        motes.renderMode = .additive
        motes.birthRate = 0
        motes.emitterCells = prism.map { color in
            Self.cell(Self.dot(64, core: 0.0), color: color.copy(alpha: 0.22)!, birthRate: 4, lifetime: 9, velocity: 14, scale: 0.6) {
                $0.lifetimeRange = 4; $0.velocityRange = 10; $0.scaleRange = 0.4; $0.alphaSpeed = -0.02
            }
        } + [Self.cell(Self.glint(48), color: .white, birthRate: 40, lifetime: 1.6, velocity: 4, scale: 0.2) {
            $0.scaleRange = 0.12; $0.scaleSpeed = -0.08; $0.alphaSpeed = -0.6; $0.spinRange = 2
        }]
        root.addSublayer(motes)

        // A ring of every colour turning slowly round the picture, glowing where it meets the dark.
        ring.frame = pictureFrame.insetBy(dx: -40, dy: -40)
        let colors = CAGradientLayer()
        colors.type = .conic
        let side = hypot(ring.bounds.width, ring.bounds.height)
        colors.frame = CGRect(x: ring.bounds.midX - side / 2, y: ring.bounds.midY - side / 2, width: side, height: side)
        colors.colors = prism + [prism[0]]
        colors.startPoint = CGPoint(x: 0.5, y: 0.5)
        colors.endPoint = CGPoint(x: 0.5, y: 0)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 7
        turn.repeatCount = .infinity
        colors.add(turn, forKey: "turn")
        ring.addSublayer(colors)
        let edge = CAShapeLayer()
        edge.frame = ring.bounds
        edge.path = CGPath(roundedRect: ring.bounds.insetBy(dx: 40, dy: 40), cornerWidth: corner, cornerHeight: corner, transform: nil)
        edge.fillColor = nil
        edge.strokeColor = .black
        edge.lineWidth = 3
        edge.shadowColor = .black
        edge.shadowOpacity = 1
        edge.shadowRadius = 18
        edge.shadowOffset = .zero
        ring.mask = edge
        ring.opacity = 0
        root.addSublayer(ring)

        picture.bounds = bounds
        picture.position = center
        picture.contents = job.image
        picture.contentsScale = job.scale
        picture.masksToBounds = true
        root.addSublayer(picture)

        // While the screen is read, a band of light runs down the picture.
        scan.frame = CGRect(x: 0, y: -260, width: size.width, height: 260)
        scan.colors = [NSColor.clear.cgColor, prism[4].copy(alpha: 0.35)!, prism[3].copy(alpha: 0.15)!, NSColor.clear.cgColor]
        scan.compositingFilter = "screenBlendMode"
        scan.opacity = 0
        picture.addSublayer(scan)

        lens.cornerRadius = 8
        lens.borderWidth = 1.5 / shrink
        lens.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        lens.backgroundColor = prism[4].copy(alpha: 0.08)
        lens.shadowColor = prism[4]
        lens.shadowRadius = 14
        lens.shadowOpacity = 1
        lens.shadowOffset = .zero
        lens.opacity = 0
        picture.addSublayer(lens)

        // Sparks pouring off the picture's edge, in every colour.
        sparks.frame = bounds
        sparks.emitterShape = .rectangle
        sparks.emitterMode = .outline
        sparks.emitterPosition = center
        sparks.emitterSize = pictureFrame.size
        sparks.renderMode = .additive
        sparks.birthRate = 0
        sparks.emitterCells = prism.flatMap { color in [
            Self.cell(Self.dot(24, core: 0.25), color: color, birthRate: 70, lifetime: 1.4, velocity: 55, scale: 0.18) {
                $0.lifetimeRange = 0.8; $0.velocityRange = 45; $0.scaleRange = 0.1; $0.scaleSpeed = -0.1; $0.alphaSpeed = -0.6
            },
            Self.cell(Self.dot(64, core: 0.0), color: color.copy(alpha: 0.35)!, birthRate: 5, lifetime: 2.5, velocity: 18, scale: 0.6) {
                $0.alphaSpeed = -0.25; $0.scaleRange = 0.3
            },
        ] } + [Self.cell(Self.glint(48), color: .white, birthRate: 30, lifetime: 0.9, velocity: 30, scale: 0.3) {
            $0.spin = 2; $0.spinRange = 3; $0.alphaSpeed = -1; $0.scaleRange = 0.15
        }]
        root.addSublayer(sparks)

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

        // Glimm's band: every colour top to bottom, a soft bell of light side to side, a hot core.
        band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: size.height)
        band.compositingFilter = "screenBlendMode"
        let hues = CAGradientLayer()
        hues.frame = band.bounds
        hues.colors = prism
        hues.mask = Self.bell(band.bounds, tightness: 18, peak: 1)
        band.addSublayer(hues)
        let core = CALayer()
        core.frame = band.bounds
        core.backgroundColor = .white
        core.mask = Self.bell(band.bounds, tightness: 90, peak: 0.7)
        band.addSublayer(core)
        root.addSublayer(band)

        // Glitter shed by the band as it passes.
        trail.frame = bounds
        trail.emitterShape = .rectangle
        trail.emitterMode = .surface
        trail.emitterSize = CGSize(width: 12, height: size.height)
        trail.emitterPosition = CGPoint(x: -bandWidth / 2, y: center.y)
        trail.renderMode = .additive
        trail.emitterCells = prism.map { color in
            Self.cell(Self.dot(24, core: 0.25), color: color, birthRate: 90, lifetime: 0.9, velocity: 45, scale: 0.16) {
                $0.emissionLongitude = .pi; $0.emissionRange = 0.7; $0.velocityRange = 30; $0.alphaSpeed = -1.1; $0.scaleRange = 0.08
            }
        }
        root.addSublayer(trail)

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
        move(trail, "emitterPosition", from: CGPoint(x: start, y: center.y), to: CGPoint(x: end, y: center.y))
        let from = start / size.width, to = end / size.width
        move(sweep, "locations", from: [from, from + 0.001], to: [to, to + 0.001])
        CATransaction.commit()

        // Behind the band, the screen springs down into a picture.
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1
        spring.toValue = shrink
        spring.damping = 15
        spring.stiffness = 130
        spring.duration = spring.settlingDuration
        picture.transform = CATransform3DMakeScale(shrink, shrink, 1)
        picture.add(spring, forKey: "shrink")
        let round = CABasicAnimation(keyPath: "cornerRadius")
        round.fromValue = 0
        round.toValue = corner / shrink
        round.duration = 0.6
        picture.cornerRadius = corner / shrink
        picture.add(round, forKey: "round")
        motes.beginTime = CACurrentMediaTime() - 4  // the background is already alive when it appears
        motes.birthRate = 1
    }

    /// The sweep has passed: the band fades, the ring lights, sparks burst off
    /// the edge, and the reading begins to show.
    private func settle() {
        guard !closing else { return }
        before.removeFromSuperlayer()
        trail.birthRate = 0
        fade(band, to: 0, duration: 0.22)
        fade(ring, to: 1, duration: 0.5)
        burst()
        if patches.isEmpty {
            let run = CABasicAnimation(keyPath: "position.y")
            run.fromValue = -130
            run.toValue = bounds.height + 130
            run.duration = 1.6
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
        burst()
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

    /// Back to the screen: the translations melt, the sparks die down and the
    /// picture grows back to fill it, exactly where everything was.
    func finish(then done: @escaping () -> Void) {
        closing = true
        follow?.invalidate()
        sparks.birthRate = 0
        trail.birthRate = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        for layer in [lens, ring, scan, sparks, trail, band] { layer.opacity = 0 }
        for id in inks.keys where inks[id]!.opacity > 0 { ink(id, in: false) }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.42)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock(done)
        before.removeFromSuperlayer()
        picture.transform = CATransform3DIdentity
        picture.cornerRadius = 0
        CATransaction.commit()
    }

    private func burst() {
        sparks.birthRate = 6
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !closing else { return }
            sparks.birthRate = 1
        }
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

    /// The screen, small and softly blurred, for the dark around the picture.
    private static func blurred(_ image: CGImage) -> CGImage? {
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1))
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: small.extent)
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

    /// A four-pointed glint: a bright dot crossed by two thin rays.
    private static func glint(_ side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(side), ray = s * 0.06
        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: 0, y: s / 2 - ray / 2, width: s, height: ray))
        context.fillEllipse(in: CGRect(x: s / 2 - ray / 2, y: 0, width: ray, height: s))
        context.draw(dot(side, core: 0.1), in: CGRect(x: s * 0.3, y: s * 0.3, width: s * 0.4, height: s * 0.4))
        return context.makeImage()!
    }
}

