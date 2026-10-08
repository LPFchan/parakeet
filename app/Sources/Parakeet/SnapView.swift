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

/// The screen springs down into a picture. Once it's read and translated, the
/// picture lights up in its own colours (its edges, blurred and stretched
/// outward, spill into the dark), and hovering a paragraph inks in its
/// translation; dragging over an area keeps everything in it translated.
final class SnapView: NSView {
    var onDismiss: () -> Void = {}
    private(set) var closing = false
    private let job: SnapJob
    private let shrink: CGFloat = 0.86
    private let corner: CGFloat = 22
    /// How far the glow reaches past the picture's edge, in points.
    private let spread: CGFloat = 200

    private let backdrop = CALayer()
    private let glow = CALayer()
    /// The screen itself, holding the translations and the lens.
    private let picture = CALayer()
    private let lens = CALayer()

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

        backdrop.frame = bounds
        backdrop.backgroundColor = CGColor(gray: 0.03, alpha: 1)
        root.addSublayer(backdrop)

        // The glow: the picture's own edges stretched out and blurred, fading into the dark.
        glow.frame = pictureFrame.insetBy(dx: -spread, dy: -spread)
        glow.contents = Self.extended(job.image, size: pictureFrame.size, spread: spread)
        glow.contentsGravity = .resize
        let fade = CAShapeLayer()
        fade.frame = glow.bounds
        fade.path = CGPath(roundedRect: glow.bounds.insetBy(dx: spread, dy: spread),  // the picture's own edge
                           cornerWidth: corner, cornerHeight: corner, transform: nil)
        fade.fillColor = .black
        fade.shadowColor = .black
        fade.shadowOpacity = 1
        fade.shadowRadius = spread * 0.42  // fading from the picture's edge, gone before the glow's own
        fade.shadowOffset = .zero
        glow.mask = fade
        glow.opacity = 0
        root.addSublayer(glow)

        picture.bounds = bounds
        picture.position = center
        picture.contents = job.image
        picture.contentsScale = job.scale
        picture.masksToBounds = true
        picture.cornerRadius = corner / shrink
        picture.transform = CATransform3DMakeScale(shrink, shrink, 1)
        root.addSublayer(picture)

        lens.cornerRadius = 8
        lens.borderWidth = 1.5 / shrink
        lens.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        lens.backgroundColor = CGColor(srgbRed: 0.4, green: 0.65, blue: 1, alpha: 0.07)
        lens.shadowColor = CGColor(srgbRed: 0.4, green: 0.65, blue: 1, alpha: 1)
        lens.shadowRadius = 14
        lens.shadowOpacity = 0.9
        lens.shadowOffset = .zero
        lens.opacity = 0
        picture.addSublayer(lens)

        let host = NSHostingView(rootView: TranslationHost(job: job))
        host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(host)

        job.onReady = { [weak self] patches in self?.read(patches) }
        job.onFail = { NSSound.beep() }  // and it stays unlit
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The screen springs down to the picture, unlit while it's being read.
    func play() {
        spring(picture, "transform.scale", to: shrink, from: 1)
        spring(picture, "cornerRadius", to: corner / shrink, from: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.settle() }
    }

    private func settle() {
        guard !closing else { return }
        // The pointer is followed by its position: a sheet over another app
        // doesn't reliably get mouse-moved events.
        follow = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.track() }
    }

    /// The translations are in: the picture lights up, and each waits, unseen, over its paragraph.
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
            picture.insertSublayer(ink, below: lens)
            inks[patch.id] = ink
        }
        guard !closing else { return }
        spring(glow, "opacity", to: 1)
        spring(glow, "transform.scale", to: 1, from: 0.97)
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
        if let id, let box = patches.first(where: { $0.id == id })?.box {
            let frame = Self.points(box, job.scale).insetBy(dx: -6, dy: -6)
            // From nowhere it appears in place; from another paragraph it glides over.
            if lens.opacity < 0.01 { lens.frame = frame } else {
                spring(lens, "position", to: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)))
                spring(lens, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: frame.size)))
            }
            spring(lens, "opacity", to: 1)
            ink(id, in: true)
        } else {
            spring(lens, "opacity", to: 0)
        }
    }

    /// Ink: the translation settles in out of a blur, or melts back into one.
    private func ink(_ id: Int, in show: Bool) {
        guard let layer = inks[id] else { return }
        spring(layer, "filters.blur.inputRadius", to: show ? 0 : 6)
        spring(layer, "opacity", to: show ? 1 : 0)
        spring(layer, "transform.scale", to: show ? 1 : 1.04)
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
            spring(lens, "opacity", to: 0)
            hovered = nil
            return patches.isEmpty ? waiting.append(area) : pin(in: area)
        }
        guard pictureFrame.contains(point) else { return onDismiss() }
        // A click keeps the paragraph under the pointer translated, or lets it go.
        if let id = hovered {
            if pinned.remove(id) == nil { pinned.insert(id) }
        }
    }

    /// Back to the screen: the translations melt, the glow goes out and the
    /// picture springs back to fill it, exactly where everything was.
    func finish(then done: @escaping () -> Void) {
        closing = true
        follow?.invalidate()
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        spring(lens, "opacity", to: 0)
        for id in inks.keys where inks[id]!.opacity > 0 { ink(id, in: false) }
        spring(picture, "transform.scale", to: 1)
        spring(picture, "cornerRadius", to: 0)
        spring(glow, "opacity", to: 0)
        spring(glow, "transform.scale", to: 1 / shrink)
        CATransaction.commit()
    }

    /// Every motion is the same crisp spring: critically damped, no bounce,
    /// settled in about a third of a second. It starts from wherever the
    /// layer is on screen, so a reversal mid-way stays smooth.
    private func spring(_ layer: CALayer, _ keyPath: String, to value: Any, from: Any? = nil) {
        let spring = CASpringAnimation(perceptualDuration: 0.34, bounce: 0)
        spring.keyPath = keyPath
        spring.fromValue = from ?? layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        spring.toValue = value
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(spring, forKey: keyPath)
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

    /// The screen at the picture's size, its edge pixels stretched `spread`
    /// outward on every side, then blurred and made a little richer: a glow
    /// in the screen's own colours. Worked at a quarter size; it's all blur.
    private static func extended(_ image: CGImage, size: CGSize, spread: CGFloat) -> CGImage? {
        let k: CGFloat = 0.25
        let source = CIImage(cgImage: image)
        let fitted = source.transformed(by: CGAffineTransform(scaleX: size.width * k / source.extent.width,
                                                              y: size.height * k / source.extent.height))
        let pad = spread * k
        let area = CGRect(x: -pad, y: -pad, width: size.width * k + 2 * pad, height: size.height * k + 2 * pad)
        let glow = fitted.clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.9, kCIInputBrightnessKey: 0.1])
            .cropped(to: area)
        return CIContext().createCGImage(glow, from: area)
    }
}
