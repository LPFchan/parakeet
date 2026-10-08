import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// The ⇧⌘1 sheet over the whole screen. Esc, ⇧⌘1 again, or a click beside
/// the picture puts the screen back.
final class SnapPanel: NSPanel {
    private let view: SnapView
    private let onClose: () -> Void
    /// Pinches only go to the app in front, so Parakeet comes forward while
    /// the picture is up and hands back to this one when it closes.
    private let previous = NSWorkspace.shared.frontmostApplication

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
        makeKeyAndOrderFront(nil)
        NSApp.activate()
        view.play()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    func dismiss() {
        guard !view.closing else { return }
        view.finish { [weak self] in
            guard let self else { return }
            orderOut(nil)
            if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate() }
            onClose()
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
    /// The screen itself, holding the marks, the translations and the drag outline.
    private let picture = CALayer()
    /// The screen inside the picture's frame, zoomed and panned by pinch and scroll.
    private let content = CALayer()
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private let lens = CALayer()

    private var patches: [Patch] = []
    private var inks: [Int: CALayer] = [:]
    /// A faint mark over every paragraph that has a translation, so it's plain what can be hovered.
    private var marks: [Int: CALayer] = [:]
    private var hovered: Int?
    private var pinned: Set<Int> = []
    /// Areas dragged over: everything in them stays translated, including what arrives later.
    private var dragged: [CGRect] = []
    /// The strip under the picture: the Translate All switch, and the download offer when there is one.
    private let strip = Strip()
    private var stripView: NSView?
    /// Shimmering placeholders while the screen is read and translated: first
    /// over each line of text, then over each paragraph still to come.
    private let pending = CALayer()
    private let pendingShape = CAShapeLayer()
    private var waitingFor: Set<Int> = []
    /// Areas being read again, harder, after a drag found nothing there.
    private var forcing: [CGRect] = []
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
        content.frame = bounds
        content.contents = job.image
        content.contentsScale = job.scale
        picture.addSublayer(content)
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
        content.addSublayer(lens)

        // macOS's own download prompt hangs off this, so it sits in the middle.
        let host = NSHostingView(rootView: TranslationHost(job: job))
        host.frame = CGRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
        addSubview(host)

        let stripView = NSHostingView(rootView: StripView(strip: strip) { [weak self] size in self?.place(strip: size) })
        stripView.sizingOptions = []
        addSubview(stripView)
        self.stripView = stripView
        strip.onShowAll = { [weak self] on in self?.showAll(on) }
        strip.onDownload = { [weak self] chosen in self?.job.download(chosen) }

        job.onSketch = { [weak self] lines in self?.sketch(lines) }
        job.onFound = { [weak self] paragraphs in self?.found(paragraphs) }
        job.onReady = { [weak self] patches in self?.read(patches) }
        job.onMissing = { [weak self] missing in
            self?.lightUp()  // what's downloaded is done
            // Added to an offer still showing, not in place of it: its languages have nowhere else to wait.
            guard let self, !closing else { return }
            let showing = strip.missing ?? []
            let added = missing.filter { new in !showing.contains { $0.id == new.id } }
            // Ticks already changed stay as they are; a new language starts ticked if it's likely.
            strip.chosen.formUnion(added.filter(\.likely).map(\.id))
            strip.missing = showing + added
        }
        job.onFinished = { [weak self] in self?.lightUp() }
        job.onFail = { [weak self] in
            NSSound.beep()  // and it stays unlit
            if let self { spring(pending, "opacity", to: 0) }
        }

        // The shimmer: a soft band of light running across the placeholders.
        pending.frame = bounds
        pending.opacity = 0
        // The placeholders themselves, cut out by the mask; blue shows on light pages and dark alike.
        pending.backgroundColor = CGColor(srgbRed: 0.4, green: 0.65, blue: 1, alpha: 0.16)
        let band = CAGradientLayer()
        band.frame = bounds
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [CGColor(srgbRed: 0.55, green: 0.8, blue: 1, alpha: 0), CGColor(srgbRed: 0.55, green: 0.8, blue: 1, alpha: 0.6),
                       CGColor(srgbRed: 0.55, green: 0.8, blue: 1, alpha: 0)]
        band.locations = [-0.3, -0.15, 0]
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.3, -0.15, 0]
        sweep.toValue = [1, 1.15, 1.3]
        sweep.duration = 1.4
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: "sweep")
        pending.addSublayer(band)
        pendingShape.frame = bounds
        pending.mask = pendingShape
        content.addSublayer(pending)
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
        self.patches += patches
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
            content.insertSublayer(ink, below: lens)
            inks[patch.id] = ink
            if strip.showAll, !closing { self.ink(patch.id, in: true) }
            // Its placeholder stops shimmering and firms up into a mark: hover it.
            waitingFor.remove(patch.id)
            if let mark = marks[patch.id], !closing {
                spring(mark, "backgroundColor", to: CGColor(srgbRed: 0.45, green: 0.7, blue: 1, alpha: 0.13))
                spring(mark, "borderColor", to: CGColor(srgbRed: 0.45, green: 0.7, blue: 1, alpha: 0.5))
            }
        }
        reshape()
        for area in dragged { pin(in: area) }
        hovered = nil
    }

    /// Where the text is, before it's read: each line shimmers.
    private func sketch(_ lines: [CGRect]) {
        guard !closing, patches.isEmpty, waitingFor.isEmpty else { return }
        reshape(lines.map { Self.points($0, job.scale).insetBy(dx: -2, dy: -1) }, corner: 3)
        spring(pending, "opacity", to: 1)
    }

    /// Read: the shimmer gathers onto the paragraphs being translated, each outlined faintly.
    private func found(_ paragraphs: [(id: Int, box: CGRect)]) {
        guard !closing else { return }
        waitingFor = Set(paragraphs.map(\.id))
        for (id, box) in paragraphs where marks[id] == nil {
            let mark = CALayer()
            mark.frame = Self.points(box, job.scale).insetBy(dx: -3, dy: -2)
            mark.cornerRadius = 6
            mark.backgroundColor = CGColor(srgbRed: 0.45, green: 0.7, blue: 1, alpha: 0.04)
            mark.borderColor = CGColor(srgbRed: 0.45, green: 0.7, blue: 1, alpha: 0.22)
            mark.borderWidth = 1 / shrink
            mark.opacity = 0
            content.insertSublayer(mark, below: pending)
            marks[id] = mark
            spring(mark, "opacity", to: 1)
        }
        reshape()
    }

    /// The shimmer covers whatever is still on its way: the paragraphs not yet translated.
    private func reshape(_ rects: [CGRect]? = nil, corner: CGFloat = 6) {
        let path = CGMutablePath()
        for rect in rects ?? (waitingFor.compactMap({ marks[$0]?.frame }) + forcing) {
            path.addRoundedRect(in: rect, cornerWidth: min(corner, rect.height / 2), cornerHeight: min(corner, rect.height / 2))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pendingShape.path = path
        CATransaction.commit()
        if rects == nil { spring(pending, "opacity", to: waitingFor.isEmpty && forcing.isEmpty ? 0 : 1) }
    }

    /// Everything that can be translated is: the picture lights up.
    private func lightUp() {
        guard !closing, glow.opacity < 1 else { return }
        spring(pending, "opacity", to: 0)
        spring(glow, "opacity", to: 1)
        spring(glow, "transform.scale", to: 1, from: 0.97)
    }


    /// Every translation at once, top to bottom; off, back to what's hovered or pinned.
    private func showAll(_ on: Bool) {
        guard !closing else { return }
        let order = patches.sorted { $0.box.minY < $1.box.minY }.map(\.id)
        for (i, id) in order.enumerated() where !pinned.contains(id) && id != hovered {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.015) { [weak self] in
                guard let self, !closing, strip.showAll == on else { return }
                ink(id, in: on)
            }
        }
    }

    /// Centred in the margin under the picture, at whatever size it wants.
    private func place(strip size: CGSize) {
        let margin = bounds.maxY - pictureFrame.maxY
        stripView?.frame = CGRect(x: bounds.midX - size.width / 2, y: pictureFrame.maxY + (margin - size.height) / 2,
                                  width: size.width, height: size.height)
    }

    private func track() {
        guard !closing, !dragging, let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let id = patch(at: point)?.id
        guard id != hovered else { return }
        if let old = hovered, !pinned.contains(old), !strip.showAll { ink(old, in: false) }
        hovered = id
        if let id { ink(id, in: true) }
    }

    /// Ink: the translation settles in out of a blur, or melts back into one.
    private func ink(_ id: Int, in show: Bool) {
        guard let layer = inks[id] else { return }
        if let mark = marks[id] { spring(mark, "opacity", to: show ? 0 : 1) }  // the translation takes its place
        spring(layer, "filters.blur.inputRadius", to: show ? 0 : 6)
        spring(layer, "opacity", to: show ? 1 : 0)
        spring(layer, "transform.scale", to: show ? 1 : 1.04)
    }

    /// Everything in a dragged area stays translated, top to bottom.
    private func pin(in area: CGRect) {
        let pixels = CGRect(x: area.minX * job.scale, y: area.minY * job.scale, width: area.width * job.scale, height: area.height * job.scale)
        let caught = patches.filter { $0.source.intersects(pixels) }.sorted { $0.source.minY < $1.source.minY }
        for (i, patch) in caught.enumerated() where !pinned.contains(patch.id) {
            pinned.insert(patch.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { [weak self] in self?.ink(patch.id, in: true) }
        }
    }

    /// The area shimmers while it's read again; what's found joins the rest and
    /// stays translated. Nothing found: the area shakes its head.
    private func force(_ area: CGRect) {
        forcing.append(area)
        reshape()
        let pixels = CGRect(x: area.minX * job.scale, y: area.minY * job.scale, width: area.width * job.scale, height: area.height * job.scale)
        Task { @MainActor in
            let found = await job.force(pixels)
            forcing.removeAll { $0 == area }
            reshape()
            guard found == 0, !closing else { return }
            NSSound.beep()
            let lens = CALayer()
            lens.frame = area
            lens.cornerRadius = 8
            lens.borderWidth = 1.5 / shrink
            lens.borderColor = CGColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 0.9)
            content.addSublayer(lens)
            let shake = CAKeyframeAnimation(keyPath: "position.x")
            shake.values = [0, -8, 7, -5, 3, 0].map { area.midX + $0 }
            shake.duration = 0.4
            lens.add(shake, forKey: "shake")
            spring(lens, "opacity", to: 0, from: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { lens.removeFromSuperlayer() }
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
            dragged.append(area)
            // Nothing known to translate there: read just that area again, harder.
            let known = marks.values.contains { $0.frame.intersects(area) }
            return known ? pin(in: area) : force(area)
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
        strip.closing = true
        follow?.invalidate()
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        spring(lens, "opacity", to: 0)
        for mark in marks.values { spring(mark, "opacity", to: 0) }
        for id in inks.keys where inks[id]!.opacity > 0 { ink(id, in: false) }
        spring(picture, "transform.scale", to: 1)
        spring(picture, "cornerRadius", to: 0)
        spring(content, "transform", to: NSValue(caTransform3D: CATransform3DIdentity))  // un-zoomed on the way out
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

    /// A point on the sheet, in the screen's own coordinates: through the
    /// picture's shrink, then the zoom and pan inside it.
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: ((point.x - center.x) / shrink - pan.x) / zoom + center.x,
                y: ((point.y - center.y) / shrink - pan.y) / zoom + center.y)
    }

    // MARK: Zoom

    /// Pinching zooms in around the fingers; up to 6×.
    override func magnify(with event: NSEvent) {
        guard !closing else { return }
        zoom(to: zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil), animated: false)
        // Let go almost back at 1×: back to the whole screen.
        if event.phase == .ended, zoom < 1.05 { zoom(to: 1, around: center, animated: true) }
    }

    /// Double-tapping with two fingers: 2.5× there, or back to the whole screen.
    override func smartMagnify(with event: NSEvent) {
        guard !closing else { return }
        zoom(to: zoom > 1.01 ? 1 : 2.5, around: convert(event.locationInWindow, from: nil), animated: true)
    }

    /// Zoomed in, two fingers move around.
    override func scrollWheel(with event: NSEvent) {
        guard !closing, zoom > 1 else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        place(pan: CGPoint(x: pan.x + event.scrollingDeltaX * step / shrink, y: pan.y + event.scrollingDeltaY * step / shrink), animated: false)
    }

    /// Keeps the point of the screen under `point` (on the sheet) where it is.
    private func zoom(to target: CGFloat, around point: CGPoint, animated: Bool) {
        let fixed = local(point)
        zoom = min(max(target, 1), 6)
        let p = CGPoint(x: (point.x - center.x) / shrink, y: (point.y - center.y) / shrink)
        place(pan: CGPoint(x: p.x - (fixed.x - center.x) * zoom, y: p.y - (fixed.y - center.y) * zoom), animated: animated)
    }

    /// Never past the screen's edges.
    private func place(pan target: CGPoint, animated: Bool) {
        let room = CGPoint(x: bounds.width * (zoom - 1) / 2, y: bounds.height * (zoom - 1) / 2)
        pan = CGPoint(x: min(max(target.x, -room.x), room.x), y: min(max(target.y, -room.y), room.y))
        let transform = CATransform3DScale(CATransform3DMakeTranslation(pan.x, pan.y, 0), zoom, zoom, 1)
        if animated { return spring(content, "transform", to: NSValue(caTransform3D: transform)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // under the fingers, exactly
        content.transform = transform
        CATransaction.commit()
    }

    private func patch(at point: CGPoint) -> Patch? {
        guard pictureFrame.contains(point) else { return nil }
        let p = local(point)
        let pixel = CGPoint(x: p.x * job.scale, y: p.y * job.scale)
        return patches.first { $0.source.insetBy(dx: -4, dy: -4).contains(pixel) }
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

/// What the strip under the picture shows.
@Observable
final class Strip {
    /// Every translation shown at once instead of on hover; remembered.
    var showAll = UserDefaults.standard.bool(forKey: "snapShowAll") {
        didSet {
            UserDefaults.standard.set(showAll, forKey: "snapShowAll")
            onShowAll(showAll)
        }
    }
    /// Languages to offer for download; nil when there's nothing to ask.
    var missing: [MissingLanguage]?
    /// The offered languages ticked for download.
    var chosen: Set<String> = []
    var closing = false
    @ObservationIgnored var onShowAll: (Bool) -> Void = { _ in }
    @ObservationIgnored var onDownload: ([Locale.Language]) -> Void = { _ in }
}

private struct StripView: View {
    let strip: Strip
    let resized: (CGSize) -> Void
    @State private var shown = false

    var body: some View {
        HStack(spacing: 10) {
            // The pill is the switch: lit while every translation shows.
            Button { strip.showAll.toggle() } label: {
                Label("Translate All", systemImage: "translate")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(strip.showAll ? .white : .white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(strip.showAll ? Color.accentColor.opacity(0.7) : .clear, in: .capsule)
                    .modifier(Pill())
                    .contentShape(.capsule)
                    .animation(.spring(duration: 0.34, bounce: 0), value: strip.showAll)
            }
            .buttonStyle(.plain)
            if let missing = strip.missing {
                DownloadOffer(missing: missing, chosen: Binding(get: { strip.chosen }, set: { strip.chosen = $0 })) { chosen in
                    withAnimation(.spring(duration: 0.34, bounce: 0)) { strip.missing = nil }
                    strip.chosen = []
                    strip.onDownload(chosen)
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .opacity(shown && !strip.closing ? 1 : 0)
        .offset(y: shown && !strip.closing ? 0 : 12)
        .animation(.spring(duration: 0.34, bounce: 0), value: strip.missing == nil)  // the same crisp spring as the rest
        .animation(.spring(duration: 0.34, bounce: 0), value: strip.closing)
        .onGeometryChange(for: CGSize.self, of: \.size) { resized($0) }
        .onAppear { withAnimation(.spring(duration: 0.34, bounce: 0).delay(0.2)) { shown = true } }
    }
}

private struct Pill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(white: 0.12).opacity(0.85), in: .capsule)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}

/// Asks which missing languages to download, before macOS asks for permission:
/// one chip per language, its text on hover.
private struct DownloadOffer: View {
    let missing: [MissingLanguage]
    @Binding var chosen: Set<String>
    let done: ([Locale.Language]) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Text("Download languages to translate?").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            ForEach(missing) { language in
                let on = chosen.contains(language.id)
                Button {
                    if on { chosen.remove(language.id) } else { chosen.insert(language.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                        Text(Translator.name(language.language)).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(on ? .white : .white.opacity(0.55))
                    .background(on ? Color.accentColor.opacity(0.55) : .white.opacity(0.08), in: .capsule)
                }
                .buttonStyle(.plain)
                .help("“\(language.sample)”")
            }
            Button("Not Now") { done([]) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 4)
                .keyboardShortcut(.cancelAction)
            Button("Download") { done(missing.filter { chosen.contains($0.id) }.map(\.language)) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(Pill())
    }
}
