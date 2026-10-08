import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision

/// ⇧⌘1: point at text on screen (or drag over an area) and it's repainted,
/// in place, in the language captions translate into. Reading, translating
/// and drawing all happen on this Mac.
final class SnapTranslate: NSObject {
    private let target: () async -> Locale.Language
    private var selection: SelectionPanel?
    private var busy = false
    private var overlay: OverlayPanel?

    init(target: @escaping () async -> Locale.Language) {
        self.target = target
        super.init()
        // Carbon's hotkeys need no Input Monitoring permission.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            let snap = Unmanaged<SnapTranslate>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { snap.start() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_1), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x5052_4B54, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    @objc func start() {
        overlay?.close()
        overlay = nil
        guard !busy, Self.canCapture() else { return }
        busy = true
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let pick = SnapPick.current
        Task { @MainActor in
            // The whole screen is captured before the sheet goes up: macOS may
            // first ask to allow the capture, and the sheet would cover its dialog.
            let image = pick == .drag ? nil : try? await Self.capture(screen.frame, on: screen)
            let panel = SelectionPanel(screen: screen, canDrag: pick != .point) { [weak self] picked in
                guard let (rect, trim) = picked else { self?.selection = nil; self?.busy = false; return }
                Task { @MainActor in
                    await self?.translate(rect, trimmingEdges: trim, on: screen)
                    self?.selection = nil
                    self?.busy = false  // only now, so a second ⇧⌘1 can't overtake the capture
                }
            }
            selection = panel
            guard let image else { return panel.blocks = [] }
            // Find the text on the whole screen, so each block can light up under
            // the pointer. Only where it is, not what it says: that takes a
            // fraction of the time, in any script.
            let scale = screen.backingScaleFactor, height = screen.frame.height
            let blocks = await Task.detached {
                let request = VNDetectTextRectanglesRequest()
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? []).map { observation in
                    let box = VNImageRectForNormalizedRect(observation.boundingBox, image.width, image.height)
                    return Line(text: "", box: CGRect(x: box.minX, y: CGFloat(image.height) - box.maxY, width: box.width, height: box.height))
                }
                return Paragraph.group(lines).map { ($0.box, $0.lineHeight) }
            }.value
            panel.blocks = blocks.map { box, lineHeight in
                TextBlock(rect: CGRect(x: box.minX / scale, y: height - box.maxY / scale, width: box.width / scale, height: box.height / scale),
                          lineHeight: lineHeight / scale)
            }
        }
    }

    /// Asks for Screen Recording once; after that, a refusal can only be
    /// undone in System Settings, so it opens there.
    private static func canCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if UserDefaults.standard.bool(forKey: "askedScreenRecording") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            UserDefaults.standard.set(true, forKey: "askedScreenRecording")
            CGRequestScreenCaptureAccess()
        }
        return false
    }

    @MainActor private func translate(_ rect: CGRect, trimmingEdges trim: Bool, on screen: NSScreen) async {
        guard let image = try? await Self.capture(rect, on: screen) else { return NSSound.beep() }
        let job = SnapJob(image: image, scale: screen.backingScaleFactor, target: await target(), trimmingEdges: trim)
        let panel = OverlayPanel(frame: rect, job: job)
        job.onFail = { [weak self, weak panel] in
            NSSound.beep()
            panel?.close()
            if self?.overlay === panel { self?.overlay = nil }
        }
        overlay = panel
        panel.makeKeyAndOrderFront(nil)  // for Esc; a non-activating panel leaves the app in front as it is
        job.read()
    }

    /// The area as it looks under Parakeet's own windows (the caption box included).
    private static func capture(_ rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CancellationError() }
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        // Display points, from the top-left corner (AppKit counts from the bottom).
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// How ⇧⌘1 picks its text; `defaults write plus.lost.parakeet snapPick point|drag` while trying them out.
enum SnapPick: String {
    case both, point, drag
    static var current: SnapPick { SnapPick(rawValue: UserDefaults.standard.string(forKey: "snapPick") ?? "") ?? .both }
}

/// How the translation arrives; `defaults write plus.lost.parakeet snapReveal shimmer|morph` while trying them out.
enum SnapReveal: String {
    case ink, shimmer, morph
    static var current: SnapReveal { SnapReveal(rawValue: UserDefaults.standard.string(forKey: "snapReveal") ?? "") ?? .ink }
}

/// One snap: the captured image, its text read into paragraphs, and those
/// translated into patches laid back over the image.
@Observable
final class SnapJob {
    let image: CGImage
    /// The lines as they're read, for the glow that follows them while translating.
    private(set) var lines: [Line] = []
    private(set) var patches: [Patch] = []
    var closing = false
    var done: Bool { !patches.isEmpty }
    /// One language at a time, once the text's languages are known; each starts `.translationTask` again.
    private(set) var configuration: TranslationSession.Configuration?
    @ObservationIgnored let scale: CGFloat
    @ObservationIgnored var onFail: () -> Void = {}
    @ObservationIgnored private let target: Locale.Language
    @ObservationIgnored private let trimmingEdges: Bool
    @ObservationIgnored private var paragraphs: [Paragraph] = []
    @ObservationIgnored private var sources: [Locale.Language] = []

    /// `trimmingEdges`: the area was cut generously around a block, so a line
    /// it cuts through belongs to some other text and is left alone.
    init(image: CGImage, scale: CGFloat, target: Locale.Language, trimmingEdges: Bool = false) {
        self.image = image
        self.scale = scale
        self.target = target
        self.trimmingEdges = trimmingEdges
    }

    func read() {
        let image = image, whole = CGRect(x: 0, y: 0, width: image.width, height: image.height).insetBy(dx: 2, dy: 2)
        Task.detached { [self] in
            let lines = Self.lines(in: image).filter { !trimmingEdges || whole.contains($0.box) }
            await MainActor.run { self.lines = lines }
            let paragraphs = Paragraph.group(lines)
            let written = paragraphs.filter { $0.text.contains(where: \.isLetter) }  // not just numbers
            let dominant = Self.language(of: written.map(\.text).joined(separator: "\n"))
            // A short paragraph is easily misread, so only a confident guess
            // overrides the language of the area as a whole.
            let foreign: [Paragraph] = written.compactMap { paragraph in
                var paragraph = paragraph
                paragraph.source = Self.language(of: paragraph.text, confidence: 0.8) ?? dominant
                let native = [Self.language(of: paragraph.text), paragraph.source].contains { $0?.isSame(as: target) == true }
                return native || paragraph.source == nil ? nil : paragraph
            }
            var sources: [Locale.Language] = []
            for source in foreign.compactMap(\.source) where !sources.contains(where: { $0.isSame(as: source) }) { sources.append(source) }
            await MainActor.run {
                guard !foreign.isEmpty else { return onFail() }
                self.paragraphs = foreign
                self.sources = sources
                configuration = .init(source: sources[0], target: target)
            }
        }
    }

    @MainActor func run(_ session: TranslationSession) async {
        guard let source = sources.first else { return }
        let requests = paragraphs.indices.filter { paragraphs[$0].source?.isSame(as: source) == true }
            .map { TranslationSession.Request(sourceText: paragraphs[$0].text, clientIdentifier: "\($0)") }
        // A language that can't be translated is left as it was.
        let responses = (try? await session.translations(from: requests)) ?? []
        if Task.isCancelled { return }
        for response in responses {
            guard let i = response.clientIdentifier.flatMap(Int.init) else { continue }
            paragraphs[i].translation = response.targetText
        }
        sources.removeFirst()
        if let next = sources.first { return configuration = .init(source: next, target: target) }
        let original = image, translated = paragraphs
        let patches = await Task.detached(operation: { Painter.patches(translated, over: original) }).value
        guard !patches.isEmpty else { return onFail() }
        self.patches = patches
    }

    /// Text lines in pixels, top-left origin, in reading order.
    private static func lines(in image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = VNImageRectForNormalizedRect(observation.boundingBox, Int(size.width), Int(size.height))
            return Line(text: text, box: CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height))
        }
    }

    private static func language(of text: String, confidence: Double = 0) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, sure) = recognizer.languageHypotheses(withMaximum: 1).first, sure >= confidence else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}

struct Line {
    let text: String
    let box: CGRect
}

/// Lines that read as one block: stacked closely, about the same size, and
/// overlapping sideways. It's translated as a whole, since a sentence often
/// wraps across lines.
struct Paragraph {
    var lines: [Line]
    var source: Locale.Language?
    var translation = ""

    var box: CGRect { lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) } }
    var lineHeight: CGFloat { lines.map(\.box.height).reduce(0, +) / CGFloat(lines.count) }

    var text: String {
        lines.dropFirst().reduce(lines[0].text) { text, line in
            // Chinese and Japanese don't put spaces where lines wrap.
            let unspaced = text.last?.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) } ?? false
            return text + (unspaced ? "" : " ") + line.text
        }
    }

    static func group(_ lines: [Line]) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            let i = paragraphs.lastIndex { paragraph in
                let last = paragraph.lines.last!.box
                let gap = line.box.minY - last.maxY
                let ratio = line.box.height / last.height
                return gap < last.height * 0.7 && gap > -last.height * 0.3 && (0.75...1.33).contains(ratio)
                    && line.box.minX < last.maxX && last.minX < line.box.maxX
            }
            if let i { paragraphs[i].lines.append(line) } else { paragraphs.append(Paragraph(lines: [line])) }
        }
        return paragraphs
    }
}

/// One paragraph's translation, ready to lay over the original: its box
/// filled with the colour around it and the translation written in the
/// original's text colour. Pixels, top-left origin.
struct Patch: Identifiable {
    let id: Int
    let box: CGRect
    let image: CGImage
    let text: String
    let fontSize: CGFloat
    /// Where the text sits inside the patch.
    let textFrame: CGRect
    let ink: NSColor
    let background: NSColor
}

enum Painter {
    static func patches(_ paragraphs: [Paragraph], over image: CGImage) -> [Patch] {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.makeImage()?.dataProvider?.data as Data? else { return [] }
        func pixel(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255
        }

        return paragraphs.enumerated().compactMap { id, paragraph in
            guard !paragraph.translation.isEmpty else { return nil }
            let pad = (paragraph.lineHeight * 0.2).rounded()
            let box = paragraph.box.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            // The background: the most common colour on the box's edge.
            var edge: [SIMD3<Double>] = []
            for x in stride(from: Int(box.minX), to: Int(box.maxX), by: 2) { edge += [pixel(x, Int(box.minY)), pixel(x, Int(box.maxY) - 1)] }
            for y in stride(from: Int(box.minY), to: Int(box.maxY), by: 2) { edge += [pixel(Int(box.minX), y), pixel(Int(box.maxX) - 1, y)] }
            let background = mode(edge)
            // The text: the inside pixels least like the background.
            var inside: [SIMD3<Double>] = []
            for line in paragraph.lines {
                for y in stride(from: Int(line.box.minY), to: Int(line.box.maxY), by: 2) {
                    for x in stride(from: Int(line.box.minX), to: Int(line.box.maxX), by: 2) { inside.append(pixel(x, y)) }
                }
            }
            let far = inside.sorted { distance($0, background) > distance($1, background) }.prefix(max(1, inside.count / 20))
            var ink = far.reduce(.zero, +) / Double(far.count)
            if distance(ink, background) < 0.3 { ink = luminance(background) > 0.5 ? .zero : .one }

            let inner = CGRect(x: pad, y: pad / 2, width: box.width - pad * 2, height: box.height - pad)
            let (text, fontSize, textFrame) = fit(paragraph.translation, color: color(ink), in: inner, size: paragraph.lineHeight * 0.8)
            guard let patch = render(text, in: textFrame, size: box.size, background: color(background)) else { return nil }
            return Patch(id: id, box: box, image: patch, text: paragraph.translation, fontSize: fontSize,
                         textFrame: textFrame, ink: color(ink), background: color(background))
        }
    }

    /// The original with every patch laid over it, as `--snap` writes it out.
    static func compose(_ patches: [Patch], over image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for patch in patches {
            context.draw(patch.image, in: CGRect(x: patch.box.minX, y: CGFloat(height) - patch.box.maxY, width: patch.box.width, height: patch.box.height))
        }
        return context.makeImage()
    }

    /// The original's size, or smaller until it fits; centred when it's one line.
    private static func fit(_ string: String, color: NSColor, in box: CGRect, size: CGFloat) -> (NSAttributedString, CGFloat, CGRect) {
        var size = size / 0.92, fitted = NSAttributedString(), bounds = CGRect.zero
        repeat {
            size *= 0.92
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineBreakStrategy = .hangulWordPriority  // Korean breaks between words, not syllables
            fitted = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                                                                     .foregroundColor: color, .paragraphStyle: style])
            bounds = fitted.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        } while bounds.height > box.height && size > 6
        let top = box.minY + max(0, (box.height - bounds.height) / 2)
        return (fitted, size, CGRect(x: box.minX, y: top, width: box.width, height: ceil(bounds.height)))
    }

    private static func render(_ text: NSAttributedString, in frame: CGRect, size: CGSize, background: NSColor) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        // Flipped, so rectangles count from the top like Vision's boxes do.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(background.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        text.draw(with: frame, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func mode(_ colors: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !colors.isEmpty else { return .one }
        // Bucket into 4-bit channels so anti-aliasing noise falls together.
        let common = Dictionary(grouping: colors) { ($0 * 15).rounded(.toNearestOrEven) }.values.max { $0.count < $1.count }!
        return common.reduce(.zero, +) / Double(common.count)
    }

    private static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { ((a - b) * (a - b)).sum().squareRoot() }
    private static func luminance(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    private static func color(_ c: SIMD3<Double>) -> NSColor { NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1) }
}

/// The glow the snap is drawn in: a cool, pale blue that shows on light and dark pages alike.
private let glow = NSColor(srgbRed: 0.45, green: 0.68, blue: 1, alpha: 1)

/// A clear sheet over the screen. The block of text under the pointer lights
/// up and a click picks it; a drag picks an area. Esc, or a click on nothing, cancels.
final class SelectionPanel: NSPanel {
    private let done: ((CGRect, trim: Bool)?) -> Void
    private let view: SelectionView
    /// The screen's blocks of text in view coordinates; nil while it's still being read.
    var blocks: [TextBlock]? {
        get { view.blocks }
        set { view.blocks = newValue }
    }

    /// `done` gets the area to read, in screen coordinates, and whether it was cut
    /// generously around a block; nil if cancelled.
    init(screen: NSScreen, canDrag: Bool, done: @escaping ((CGRect, trim: Bool)?) -> Void) {
        self.done = done
        view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), canDrag: canDrag)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false  // clicks on the clear sheet are ours, not the app's beneath
        contentView = view
        view.onDone = { [weak self] picked in
            self?.finish(picked.map { ($0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY).intersection(screen.frame), $1) })
        }
        makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ picked: (CGRect, trim: Bool)?) {
        NSCursor.pop()
        orderOut(nil)
        done(picked.flatMap { $0.0.width >= 8 && $0.0.height >= 8 ? $0 : nil })
    }
}

/// A block of text found on screen, in view coordinates.
struct TextBlock {
    let rect: CGRect
    let lineHeight: CGFloat
}

private final class SelectionView: NSView {
    var onDone: ((CGRect, trim: Bool)?) -> Void = { _ in }
    var blocks: [TextBlock]? { didSet { if blocks != nil { read() } } }
    private let canDrag: Bool
    private var start: CGPoint?
    private var dragging = false
    private var hovered: TextBlock?
    /// The glowing outline that glides from block to block, and stretches as an area is dragged.
    private let lens = CALayer()
    /// A band of light that sweeps down the screen while it's being read.
    private let scan = CAGradientLayer()

    init(frame: CGRect, canDrag: Bool) {
        self.canDrag = canDrag
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
        lens.cornerRadius = 8
        lens.borderWidth = 1.5
        lens.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        lens.backgroundColor = glow.withAlphaComponent(0.12).cgColor
        lens.shadowColor = glow.cgColor
        lens.shadowRadius = 14
        lens.shadowOpacity = 1
        lens.shadowOffset = .zero
        lens.opacity = 0
        layer?.addSublayer(lens)
        scan.colors = [NSColor.clear, glow.withAlphaComponent(0.16), NSColor.clear].map(\.cgColor)
        scan.frame = CGRect(x: 0, y: frame.height, width: frame.width, height: 240)
        layer?.addSublayer(scan)
        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = frame.height + 120
        sweep.toValue = -120
        sweep.duration = 1.1
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scan.add(sweep, forKey: "sweep")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// The screen has been read: the sweep fades, and from now on whatever is
    /// under the pointer lights up. The pointer is followed by its position,
    /// not mouse-moved events, which a sheet over another app doesn't reliably get.
    private func read() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        scan.opacity = 0
        CATransaction.commit()
        Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self, let window, window.isVisible else { return timer.invalidate() }
            if !dragging { hover(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) }
        }
    }

    private func hover(at point: CGPoint) {
        let block = blocks?.first { $0.rect.insetBy(dx: -8, dy: -8).contains(point) }
        guard block?.rect != hovered?.rect else { return }
        hovered = block
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if let block { lens.frame = block.rect.insetBy(dx: -8, dy: -8) }
        lens.opacity = block == nil ? 0 : 1
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard canDrag, let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(point.x - start.x, point.y - start.y) < 4 { return }
        dragging = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // the outline follows the pointer exactly
        lens.frame = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
        lens.opacity = 1
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { return onDone((lens.frame, false)) }
        // The quick look can miss a short last line, so read well around the
        // block; whatever the edges cut through is left out.
        onDone(hovered.map { ($0.rect.insetBy(dx: -$0.lineHeight, dy: -$0.lineHeight * 2), true) })
    }
}

/// The translation, laid exactly over the area it came from. A click or Esc
/// melts it back into the original.
final class OverlayPanel: NSPanel {
    private let job: SnapJob

    init(frame: CGRect, job: SnapJob) {
        self.job = job
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // no card: the page itself seems to change language
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: OverlayView(job: job, reveal: .current) { [weak self] in self?.dismiss() })
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func dismiss() {
        guard job.done, !job.closing else { return close() }
        job.closing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.close() }
    }
}

private struct OverlayView: View {
    let job: SnapJob
    let reveal: SnapReveal
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: job.image, scale: job.scale)
            if job.done {
                PatchesView(patches: job.patches, scale: job.scale, reveal: reveal, closing: job.closing)
            } else {
                ReadingGlow(lines: job.lines, scale: job.scale).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: job.done)
        .contentShape(.rect)
        .onTapGesture(perform: close)
        .translationTask(job.configuration) { session in await job.run(session) }
    }
}

/// While it translates, a soft light runs along each line in reading order, like an eye reading it.
private struct ReadingGlow: View {
    let lines: [Line]
    let scale: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(lines.indices, id: \.self) { i in
                    let box = lines[i].box
                    let phase = (t * 0.8 - Double(i) * 0.15).truncatingRemainder(dividingBy: 1.6) - 0.3
                    RoundedRectangle(cornerRadius: box.height / scale * 0.3)
                        .fill(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                     .init(color: Color(nsColor: glow).opacity(0.5), location: min(max(phase, 0.01), 0.99)),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                        .blur(radius: 3)
                        .frame(width: box.width / scale + 8, height: box.height / scale + 4)
                        .offset(x: box.minX / scale - 4, y: box.minY / scale - 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PatchesView: View {
    let patches: [Patch]
    let scale: CGFloat
    let reveal: SnapReveal
    let closing: Bool
    @State private var shown = false
    @State private var sweep: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(patches.enumerated()), id: \.element.id) { i, patch in
                    piece(patch, order: i)
                        .frame(width: patch.box.width / scale, height: patch.box.height / scale)
                        .offset(x: patch.box.minX / scale, y: patch.box.minY / scale)
                        // Dissolving away: each melts back into the original, the last first.
                        .opacity(closing ? 0 : 1)
                        .blur(radius: closing ? 8 : 0)
                        .animation(.easeIn(duration: 0.3).delay(closing ? Double(patches.count - 1 - i) * 0.05 : 0), value: closing)
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: .topLeading)
            .mask(alignment: .leading) {
                if reveal == .shimmer {
                    // Everything left of the band has changed language.
                    HStack(spacing: 0) {
                        Rectangle().frame(width: max(0, sweep * (width + 80) - 80))
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 80)
                        Spacer(minLength: 0)
                    }
                } else {
                    Rectangle()
                }
            }
            .overlay(alignment: .leading) {
                if reveal == .shimmer {
                    LinearGradient(colors: [.clear, Color(nsColor: glow).opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 90)
                        .blur(radius: 6)
                        .offset(x: sweep * (width + 80) - 85)
                        .opacity(sweep < 1 ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            shown = true
            withAnimation(.easeInOut(duration: 1.1)) { sweep = 1 }
        }
    }

    @ViewBuilder private func piece(_ patch: Patch, order: Int) -> some View {
        switch reveal {
        case .ink:
            // Each paragraph settles in like ink, top to bottom.
            Image(decorative: patch.image, scale: scale)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 6)
                .scaleEffect(shown ? 1 : 1.04)
                .animation(.easeOut(duration: 0.55).delay(Double(order) * 0.1), value: shown)
        case .shimmer:
            Image(decorative: patch.image, scale: scale)
        case .morph:
            MorphPiece(patch: patch, scale: scale, delay: Double(order) * 0.12)
        }
    }
}

/// The paragraph's letters tumble through their alphabet and settle, left to right, into the translation.
private struct MorphPiece: View {
    let patch: Patch
    let scale: CGFloat
    let delay: Double
    private let duration = 0.9
    @State private var start = Date()
    @State private var settled = false

    var body: some View {
        if settled {
            Image(decorative: patch.image, scale: scale)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let progress = (context.date.timeIntervalSince(start) - delay) / duration
                ZStack(alignment: .topLeading) {
                    Color(nsColor: patch.background)
                    Text(scrambled(min(max(progress, 0), 1), tick: Int(context.date.timeIntervalSinceReferenceDate * 24)))
                        .font(.system(size: patch.fontSize / scale, weight: .medium))
                        .foregroundStyle(Color(nsColor: patch.ink))
                        .frame(width: patch.textFrame.width / scale, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: patch.textFrame.minX / scale, y: patch.textFrame.minY / scale)
                }
                .opacity(progress > 0 ? 1 : 0)
            }
            .task {
                try? await Task.sleep(for: .seconds(delay + duration))
                settled = true
            }
        }
    }

    private func scrambled(_ progress: Double, tick: Int) -> String {
        let letters = Array(patch.text)
        let done = Int(Double(letters.count) * progress)
        var seed = UInt64(truncatingIfNeeded: tick &* 7919 &+ patch.id)
        func random(_ range: ClosedRange<UInt32>) -> Character {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let value = range.lowerBound + UInt32(truncatingIfNeeded: seed >> 33) % (range.upperBound - range.lowerBound + 1)
            return Character(Unicode.Scalar(value)!)
        }
        return String(letters.enumerated().map { i, letter in
            guard i >= done, let scalar = letter.unicodeScalars.first?.value else { return letter }
            switch scalar {
            case 0xAC00...0xD7A3: return random(0xAC00...0xD7A3)  // Hangul
            case 0x4E00...0x9FFF: return random(0x4E00...0x9FFF)  // CJK
            case 0x3041...0x30FF: return random(0x3041...0x3096)  // kana
            case 0x61...0x7A: return random(0x61...0x7A)
            case 0x41...0x5A: return random(0x41...0x5A)
            case 0x30...0x39: return random(0x30...0x39)
            default: return letter
            }
        })
    }
}

extension Locale.Language {
    /// Same language in the same script: Simplified and Traditional Chinese
    /// differ, British and American English don't.
    func isSame(as other: Locale.Language) -> Bool {
        func script(_ language: Locale.Language) -> Locale.Script? { Locale.Language(identifier: language.maximalIdentifier).script }
        return languageCode == other.languageCode && script(self) == script(other)
    }
}
