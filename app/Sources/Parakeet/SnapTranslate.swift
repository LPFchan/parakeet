import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision

/// ⇧⌘1: the screen shrinks into a picture, every paragraph on it is read and
/// translated, and hovering one shows it in the language captions translate
/// into. Reading, translating and drawing all happen on this Mac.
final class SnapTranslate: NSObject {
    private let target: () async -> Locale.Language
    private var panel: SnapPanel?
    private var busy = false

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

    /// Opens the picture, or closes it when it's already up.
    @objc func start() {
        if let panel { return panel.dismiss() }
        guard !busy, Self.canCapture() else { return }
        busy = true
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        Task { @MainActor in
            defer { busy = false }
            // Captured before anything is shown: macOS may first ask to allow
            // the capture, and the picture would cover its dialog.
            guard let image = try? await Self.capture(screen) else { return NSSound.beep() }
            let job = SnapJob(image: image, scale: screen.backingScaleFactor, target: await target())
            panel = SnapPanel(screen: screen, job: job) { [weak self] in self?.panel = nil }
            job.read()
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

    /// The screen as it looks under Parakeet's own windows (the caption box included).
    private static func capture(_ screen: NSScreen) async throws -> CGImage {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CancellationError() }
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// One snap: the captured screen, its text read into paragraphs, and those
/// translated into patches that can be laid back over it.
@Observable
final class SnapJob {
    /// One language at a time, once the text's languages are known; each starts `.translationTask` again.
    private(set) var configuration: TranslationSession.Configuration?
    @ObservationIgnored let image: CGImage
    @ObservationIgnored let scale: CGFloat
    @ObservationIgnored var onReady: ([Patch]) -> Void = { _ in }
    /// Nothing on the screen needs translating, or nothing could be.
    @ObservationIgnored var onFail: () -> Void = {}
    @ObservationIgnored private let target: Locale.Language
    @ObservationIgnored private var paragraphs: [Paragraph] = []
    @ObservationIgnored private var sources: [Locale.Language] = []

    init(image: CGImage, scale: CGFloat, target: Locale.Language) {
        self.image = image
        self.scale = scale
        self.target = target
    }

    func read() {
        let image = image
        Task.detached { [self] in
            let paragraphs = Paragraph.group(Self.lines(in: image))
            let written = paragraphs.filter { $0.text.contains(where: \.isLetter) }  // not just numbers
            let dominant = Self.language(of: written.map(\.text).joined(separator: "\n"))
            // A short paragraph is easily misread, so only a confident guess
            // overrides the language of the screen as a whole.
            let japanese = written.contains { $0.text.unicodeScalars.contains { (0x3041...0x30FF).contains($0.value) } }
            let foreign: [Paragraph] = written.compactMap { paragraph in
                var paragraph = paragraph
                paragraph.source = Self.language(of: paragraph.text, confidence: 0.8) ?? dominant
                // Kanji alone (日時：10月12日…) don't say which language they're in,
                // and the detector leans Traditional Chinese. With Japanese (kana)
                // elsewhere on the screen, they're Japanese too; Simplified
                // characters (下载完成后…) are not, so a clear Simplified guess stands.
                let simplified = paragraph.source?.isSame(as: Locale.Language(identifier: "zh-Hans")) == true
                if japanese, !simplified, Self.onlyHan(paragraph.text) { paragraph.source = Locale.Language(identifier: "ja") }
                let native = [Self.language(of: paragraph.text), paragraph.source].contains { $0?.isSame(as: target) == true }
                return native || paragraph.source == nil ? nil : paragraph
            }
            // The main language may ask once to download; a stray guess
            // (a romanized place name read as Indonesian) mustn't, so other
            // languages are only translated if they're already installed.
            let main = Self.language(of: foreign.map(\.text).joined(separator: "\n"))
            var sources: [Locale.Language] = []
            for source in foreign.compactMap(\.source) where !sources.contains(where: { $0.isSame(as: source) }) {
                let installed = await LanguageAvailability().status(from: source, to: target) == .installed
                if installed || main.map(source.isSame) == true { sources.append(source) }
            }
            let kept = foreign.filter { paragraph in sources.contains { paragraph.source?.isSame(as: $0) == true } }
            let chosen = sources
            await MainActor.run {
                guard !kept.isEmpty else { return onFail() }
                self.paragraphs = kept
                self.sources = chosen
                configuration = .init(source: chosen[0], target: target)
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
        patches.isEmpty ? onFail() : onReady(patches)
    }

    /// Text lines in pixels, top-left origin. Read whole, Vision misses small
    /// lines (a lone "ん。" ending a sentence, flipping its meaning), so the
    /// screen is also read in four overlapping quarters, all at once, and any
    /// line the whole pass missed is added from those.
    private static func lines(in image: CGImage) -> [Line] {
        let w = image.width / 2, h = image.height / 2, pad = 80
        let tiles = [CGRect(x: 0, y: 0, width: image.width, height: image.height)] + (0..<4).map { i in
            let x = max((i % 2) * w - pad, 0), y = max((i / 2) * h - pad, 0)
            return CGRect(x: x, y: y, width: min(w + 2 * pad, image.width - x), height: min(h + 2 * pad, image.height - y))
        }
        var found = [[Line]](repeating: [], count: tiles.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            guard let crop = image.cropping(to: tiles[i]) else { return }
            let lines = recognize(crop).map { Line(text: $0.text, box: $0.box.offsetBy(dx: tiles[i].minX, dy: tiles[i].minY)) }
            lock.lock(); found[i] = lines; lock.unlock()
        }
        var lines = found[0]
        for line in found.dropFirst().joined() where !lines.contains(where: { overlap($0.box, line.box) > 0.3 }) {
            lines.append(line)
        }
        return lines
    }

    private static func recognize(_ image: CGImage) -> [Line] {
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

    /// Letters, but every one a Chinese character: no kana, no hangul, no Latin.
    private static func onlyHan(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// How much of the smaller box the two share.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        return shared.width * shared.height / max(min(a.width * a.height, b.width * b.height), 1)
    }

    private static func language(of text: String, confidence: Double = 0) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, sure) = recognizer.languageHypotheses(withMaximum: 1).first, sure >= confidence else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}

/// `.translationTask` only runs inside a window; this is the job's.
struct TranslationHost: View {
    let job: SnapJob

    var body: some View {
        Color.clear.translationTask(job.configuration) { session in await job.run(session) }
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
            let (text, frame) = fit(paragraph.translation, color: color(ink), in: inner, size: paragraph.lineHeight * 0.8)
            guard let patch = render(text, in: frame, size: box.size, background: color(background)) else { return nil }
            return Patch(id: id, box: box, image: patch)
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
    private static func fit(_ string: String, color: NSColor, in box: CGRect, size: CGFloat) -> (NSAttributedString, CGRect) {
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
        return (fitted, CGRect(x: box.minX, y: top, width: box.width, height: ceil(bounds.height)))
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

extension Locale.Language {
    /// Same language in the same script: Simplified and Traditional Chinese
    /// differ, British and American English don't.
    func isSame(as other: Locale.Language) -> Bool {
        func script(_ language: Locale.Language) -> Locale.Script? { Locale.Language(identifier: language.maximalIdentifier).script }
        return languageCode == other.languageCode && script(self) == script(other)
    }
}
