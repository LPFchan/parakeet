import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision

/// ⇧⌘1: drag over part of the screen and its text is repainted, in place,
/// in the language captions translate into. Reading, translating and drawing
/// all happen on this Mac.
final class SnapTranslate: NSObject {
    private let target: () -> Locale.Language
    private var selection: SelectionPanel?
    private var overlay: OverlayPanel?

    init(target: @escaping () -> Locale.Language) {
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
        guard selection == nil, Self.canCapture() else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        selection = SelectionPanel(screen: screen) { [weak self] rect in
            self?.selection = nil
            guard let rect else { return }
            Task { @MainActor in await self?.translate(rect, on: screen) }
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

    @MainActor private func translate(_ rect: CGRect, on screen: NSScreen) async {
        guard let image = try? await Self.capture(rect, on: screen) else { return NSSound.beep() }
        let job = SnapJob(image: image, scale: screen.backingScaleFactor, target: target())
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

/// One snap: the captured image, its text read into paragraphs, and those
/// translated and painted back over the image.
@Observable
final class SnapJob {
    private(set) var image: CGImage
    private(set) var done = false
    /// Set once the text's language is known; starts `.translationTask`.
    private(set) var configuration: TranslationSession.Configuration?
    @ObservationIgnored let scale: CGFloat
    @ObservationIgnored var onFail: () -> Void = {}
    @ObservationIgnored private let target: Locale.Language
    @ObservationIgnored private var paragraphs: [Paragraph] = []

    init(image: CGImage, scale: CGFloat, target: Locale.Language) {
        self.image = image
        self.scale = scale
        self.target = target
    }

    func read() {
        let image = image
        Task.detached { [self] in
            let lines = Self.lines(in: image)
            let paragraphs = Paragraph.group(lines)
            // Text already in the target language, and numbers, stay as they are.
            let foreign = paragraphs.filter { paragraph in
                paragraph.text.contains(where: \.isLetter) && Self.language(of: paragraph.text) != target.languageCode
            }
            let source = Self.language(of: foreign.map(\.text).joined(separator: "\n"))
            await MainActor.run {
                guard let source, !foreign.isEmpty else { return onFail() }
                self.paragraphs = foreign
                configuration = .init(source: Locale.Language(languageCode: source), target: target)
            }
        }
    }

    @MainActor func run(_ session: TranslationSession) async {
        let requests = paragraphs.indices.map { TranslationSession.Request(sourceText: paragraphs[$0].text, clientIdentifier: "\($0)") }
        guard let responses = try? await session.translations(from: requests) else { return onFail() }
        for response in responses {
            guard let i = response.clientIdentifier.flatMap(Int.init) else { continue }
            paragraphs[i].translation = response.targetText
        }
        let original = image, translated = paragraphs
        guard let painted = await Task.detached(operation: { Painter.paint(translated, over: original) }).value else { return onFail() }
        self.image = painted
        done = true
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

    private static func language(of text: String) -> Locale.LanguageCode? {
        NLLanguageRecognizer.dominantLanguage(for: text).map { Locale.Language(identifier: $0.rawValue).languageCode } ?? nil
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

/// Covers each paragraph with the colour around it and writes its
/// translation there, in the original's text colour, as large as fits.
enum Painter {
    static func paint(_ paragraphs: [Paragraph], over image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Read pixels from a copy: the context is painted over as we go.
        guard let source = context.makeImage(), let pixels = source.dataProvider?.data as Data? else { return nil }
        func pixel(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255
        }

        NSGraphicsContext.saveGraphicsState()
        // Flipped, so rectangles count from the top like Vision's boxes do.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for paragraph in paragraphs where !paragraph.translation.isEmpty {
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

            context.setFillColor(color(background).cgColor)
            context.fill(box)
            let text = NSAttributedString(string: paragraph.translation, attributes: [.foregroundColor: color(ink)])
            draw(text, in: box.insetBy(dx: pad, dy: pad / 2), size: paragraph.lineHeight * 0.8)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The original's size, or smaller until it fits; centred when it's one line.
    private static func draw(_ text: NSAttributedString, in box: CGRect, size: CGFloat) {
        var size = size, fitted = text, bounds = CGRect.zero
        repeat {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineBreakStrategy = .hangulWordPriority  // Korean breaks between words, not syllables
            let attributed = NSMutableAttributedString(attributedString: text)
            attributed.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .medium), .paragraphStyle: style],
                                     range: NSRange(location: 0, length: text.length))
            fitted = attributed
            bounds = fitted.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            size *= 0.92
        } while bounds.height > box.height && size > 6
        let top = box.minY + max(0, (box.height - bounds.height) / 2)
        fitted.draw(with: CGRect(x: box.minX, y: top, width: box.width, height: box.maxY - top), options: [.usesLineFragmentOrigin])
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

/// A dimmed screen to drag a rectangle across. Esc or a click without a drag cancels.
final class SelectionPanel: NSPanel {
    private let done: (CGRect?) -> Void
    private let view = SelectionView()

    init(screen: NSScreen, done: @escaping (CGRect?) -> Void) {
        self.done = done
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        contentView = view
        view.onDone = { [weak self] rect in self?.finish(rect.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }) }
        makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ rect: CGRect?) {
        NSCursor.pop()
        orderOut(nil)
        done(rect.flatMap { $0.width >= 8 && $0.height >= 8 ? $0 : nil })
    }
}

private final class SelectionView: NSView {
    var onDone: (CGRect?) -> Void = { _ in }
    private var start: CGPoint?
    private var rect: CGRect? { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
    }

    override func mouseUp(with event: NSEvent) { onDone(rect) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.2).setFill()
        bounds.fill()
        guard let rect else { return }
        rect.fill(using: .clear)
        NSColor.white.setStroke()
        NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}

/// The translated image, laid exactly over the area it came from. A click or Esc closes it.
final class OverlayPanel: NSPanel {
    init(frame: CGRect, job: SnapJob) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: OverlayView(job: job) { [weak self] in self?.close() })
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct OverlayView: View {
    let job: SnapJob
    let close: () -> Void

    var body: some View {
        Image(decorative: job.image, scale: job.scale)
            .resizable()
            .overlay(alignment: .topTrailing) {
                if !job.done { ProgressView().controlSize(.small).padding(6) }
            }
            .contentShape(.rect)
            .onTapGesture(perform: close)
            .translationTask(job.configuration) { session in await job.run(session) }
    }
}
