import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision
import VisionKit

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
    @MainActor @objc func start() {
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
            // What's under the pointer is translated first.
            let mouse = NSEvent.mouseLocation, scale = screen.backingScaleFactor
            job.focus = CGPoint(x: (mouse.x - screen.frame.minX) * scale, y: (screen.frame.maxY - mouse.y) * scale)
            panel = SnapPanel(screen: screen, job: job) { [weak self] in self?.panel = nil }
            job.read()
        }
    }

    /// Without Screen Recording, System Settings opens at the list with
    /// PermissionFlow's panel beside it, to drag Parakeet into.
    /// The running app's own answer never changes, so a grant made since it
    /// started (without reopening it) is checked with a fresh copy.
    @MainActor static func canCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() || ScreenRecording.allowed { return true }
        ScreenRecording.open()
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
/// translated into patches that can be laid back over it, one by one.
@Observable
final class SnapJob {
    /// A translation session per language in flight; `.translationTask` runs each.
    private(set) var sessions: [Session] = []
    @ObservationIgnored let image: CGImage
    @ObservationIgnored let scale: CGFloat
    /// Where the text is, before it's read (pixels): lines, found almost at once.
    @ObservationIgnored var onSketch: ([CGRect]) -> Void = { _ in }
    /// Paragraphs to be translated, by id and box (pixels): the screen's, then any a forced read finds.
    @ObservationIgnored var onFound: ([(id: Int, box: CGRect)]) -> Void = { _ in }
    /// Translations as they come in, paragraph by paragraph.
    @ObservationIgnored var onReady: ([Patch]) -> Void = { _ in }
    /// Languages on screen that aren't downloaded yet; answer with `download`.
    @ObservationIgnored var onMissing: ([MissingLanguage]) -> Void = { _ in }
    /// Nothing on the screen needs translating, or nothing could be.
    @ObservationIgnored var onFail: () -> Void = {}
    /// Everything chosen has been translated.
    @ObservationIgnored var onFinished: () -> Void = {}
    /// Paragraphs that won't be translated after all (their download declined or failed).
    @ObservationIgnored var onDropped: ([Int]) -> Void = { _ in }
    /// Languages offered for download that nothing needs any more: what needed them was read again.
    @ObservationIgnored var onWithdrawn: ([Locale.Language]) -> Void = { _ in }
    /// Paragraphs nearest this point (pixels) are translated first.
    @ObservationIgnored var focus: CGPoint?
    @ObservationIgnored private let target: Locale.Language
    @ObservationIgnored private var paragraphs: [Paragraph] = []
    /// Every line read, translated or not, so a translation leaves the others showing.
    @ObservationIgnored private var lines: [CGRect] = []
    /// The screen's main language, for paragraphs too short to tell.
    @ObservationIgnored private var dominant: Locale.Language?
    /// Languages chosen for download, one at a time so macOS's prompts don't stack.
    @ObservationIgnored private var downloads: [Locale.Language] = []
    @ObservationIgnored private var missing: [MissingLanguage] = []
    /// Paragraphs a session has taken on, so none is translated twice.
    @ObservationIgnored private var claimed: Set<Int> = []
    /// Given up on; a forced read of their area may find them again.
    @ObservationIgnored private var dropped: Set<Int> = []
    @ObservationIgnored private var painted = false
    @ObservationIgnored private var painter: Painter?
    /// The whole-screen read, which a forced read waits for.
    @ObservationIgnored private var reading: Task<Void, Never>?

    struct Session: Identifiable {
        let id = UUID()
        let source: Locale.Language
        let paragraphs: [Int]
        /// Downloading its language: only it moves the download queue on, so macOS's prompts come one at a time.
        var downloading = false
        let configuration: TranslationSession.Configuration
    }

    init(image: CGImage, scale: CGFloat, target: Locale.Language) {
        self.image = image
        self.scale = scale
        self.target = target
    }

    func read() {
        let image = image
        reading = Task.detached { [self] in
            let sketch = Self.sketch(image)
            await MainActor.run { onSketch(sketch) }
            let lines = await Self.lines(in: image)
            let paragraphs = Paragraph.group(lines)
            let dominant = Self.language(of: paragraphs.map(\.text).joined(separator: "\n"))
            let painter = Painter(image)
            await MainActor.run {
                self.painter = painter
                self.dominant = dominant
                self.lines = lines.map(\.box)
            }
            let found = await take(paragraphs)
            await MainActor.run { if found == 0 { onFail() } }
        }
    }

    /// Whether a drag over this area (pixels) should read it again: nothing
    /// found there yet, or something only guessed at or left untranslated.
    @MainActor func unsettled(_ area: CGRect) -> Bool {
        let there = paragraphs.indices.filter { !dropped.contains($0) && paragraphs[$0].box.intersects(area) }
        return there.isEmpty || there.contains { !held.contains($0) }
    }

    /// Reads just this area (pixels) again, harder: twice the size, with the
    /// dictionary pass. For text the whole-screen read missed or misread
    /// ("AnthropicかOpenAiが" read whole as "Anthropict OpenAi$*");
    /// returns how many new paragraphs it found to translate.
    /// On the main actor, like everything that touches the job's state; only the reading runs elsewhere.
    @MainActor func force(_ area: CGRect) async -> Int {
        let image = image
        await reading?.value  // what the whole read finds isn't found twice
        // Whatever it may replace is read whole, not just the lines dragged over.
        let held = held
        let area = paragraphs.indices.filter { !dropped.contains($0) && !held.contains($0) && paragraphs[$0].box.intersects(area) }
            .reduce(area) { $0.union(paragraphs[$1].box.insetBy(dx: -8, dy: -8)) }
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard area.width > 4, area.height > 4, let crop = image.cropping(to: area) else { return 0 }
        let known = held.map { paragraphs[$0].box }
        let lines = await Task.detached {
            let columns = await Self.columns(in: crop).map { line in
                var line = line
                line.box = line.box.offsetBy(dx: area.minX, dy: area.minY)
                return line
            }
            let rows = Self.recognize(Self.enlarged(crop), correct: true).map { line in
                Line(text: line.text, box: CGRect(x: area.minX + line.box.minX / 2, y: area.minY + line.box.minY / 2,
                                                   width: line.box.width / 2, height: line.box.height / 2), confidence: line.confidence)
            }
            return Self.merge(rows, columns).filter { line in !known.contains { Self.overlap($0, line.box) > 0.3 } }
        }.value
        self.lines += lines.map(\.box)
        return await take(Paragraph.group(lines))
    }

    /// Sorts new paragraphs by language: downloaded ones start translating at
    /// once, the rest are offered for download, each with a sample of its text
    /// so a stray guess (a place name read as Indonesian) is easy to spot.
    /// Returns how many there are to translate.
    private func take(_ found: [Paragraph]) async -> Int {
        let target = target, dominant = await MainActor.run { self.dominant }
        let written = found.filter { $0.text.contains(where: \.isLetter) }  // not just numbers
        // A short paragraph is easily misread, so only a confident guess
        // overrides the language of the screen as a whole.
        // Kana in this batch, or a Japanese screen around a forced read of just a label.
        let japanese = dominant?.languageCode == "ja"
            || written.contains { $0.text.unicodeScalars.contains { (0x3041...0x30FF).contains($0.value) } }
        let foreign: [Paragraph] = written.compactMap { paragraph in
            var paragraph = paragraph
            // Beside Latin the detector all but ignores kana; among Chinese or
            // Korean it doesn't (这是我的の新作品 is Chinese, 99% sure).
            let guess = Self.language(of: paragraph.text, confidence: 0.8)
            let asian = ["zh", "ko"].contains(guess?.languageCode?.identifier)
            paragraph.source = !asian && Self.mostlyJapanese(paragraph.text) ? Locale.Language(identifier: "ja") : guess ?? dominant
            // Kanji alone (日時：10月12日…) don't say which language they're in,
            // and the detector leans Traditional Chinese. With Japanese (kana)
            // nearby, they're Japanese too; Simplified characters (下载完成后…)
            // are not, so a clear Simplified guess stands.
            let simplified = paragraph.source?.isSame(as: Locale.Language(identifier: "zh-Hans")) == true
            if japanese, !simplified, Self.onlyHan(paragraph.text) { paragraph.source = Locale.Language(identifier: "ja") }
            let native = [Self.language(of: paragraph.text), paragraph.source].contains { $0?.isSame(as: target) == true }
            return native || paragraph.source == nil ? nil : paragraph
        }
        var ready: [Locale.Language] = [], absent: [MissingLanguage] = []
        for source in foreign.compactMap(\.source) where !(ready + absent.map(\.language)).contains(where: { $0.isSame(as: source) }) {
            let mine = foreign.filter { $0.source?.isSame(as: source) == true }
            switch await LanguageAvailability().status(from: source, to: target) {
            case .installed: ready.append(source)
            case .supported:
                // Judged by what Vision read with confidence: its guesses at a
                // blurry scrap are as likely to be another language altogether.
                let sure = mine.filter { $0.lines.contains { $0.confidence > 0.4 } }
                let longest = (sure.isEmpty ? mine : sure).max { Self.weight($0.text) < Self.weight($1.text) }!.text
                absent.append(MissingLanguage(language: source, sample: longest, weight: sure.isEmpty ? 0 : Self.weight(longest)))
            default: break  // Translation can't do this pair at all
            }
        }
        let kept = foreign.filter { paragraph in (ready + absent.map(\.language)).contains { paragraph.source?.isSame(as: $0) == true } }
        let languages = ready, offered = absent
        return await MainActor.run {
            // Two forced reads of one area at once mustn't add it twice, nor a
            // read that comes out the same as before.
            let live = paragraphs.indices.filter { !dropped.contains($0) }
            let held = held
            let kept = kept.filter { new in
                !live.contains { i in
                    Self.overlap(paragraphs[i].box, new.box) > 0.5 && (held.contains(i) || paragraphs[i].text == new.text)
                }
            }
            // What it was read as before (misread, or waiting on a download)
            // gives way, even to text now found to need no translating.
            let stale = live.filter { i in
                !held.contains(i) && written.contains { Self.overlap($0.box, paragraphs[i].box) > 0.3 && $0.text != paragraphs[i].text }
            }
            let first = paragraphs.count
            paragraphs += kept
            onFound(kept.indices.map { (first + $0, kept[$0].box) })
            drop(stale)
            // A download offered only for what gave way is taken back.
            let gone = stale.compactMap { paragraphs[$0].source }.filter { language in
                !paragraphs.indices.contains { !dropped.contains($0) && paragraphs[$0].source?.isSame(as: language) == true }
            }
            missing.removeAll { offer in gone.contains { $0.isSame(as: offer.language) } }
            if !gone.isEmpty { onWithdrawn(gone) }
            for language in offered where !missing.contains(where: { $0.language.isSame(as: language.language) }) {
                missing.append(language)
            }
            for language in languages { start(language) }
            if languages.isEmpty, !offered.isEmpty, sessions.isEmpty { askForMissing() }
            return kept.count
        }
    }

    /// Translates the chosen languages; for each, macOS first asks for permission to download it.
    func download(_ languages: [Locale.Language]) {
        // The languages not chosen: their paragraphs won't be translated.
        drop(paragraphs.indices.filter { i in
            !claimed.contains(i) && !dropped.contains(i) && paragraphs[i].translation.isEmpty
                && !languages.contains { paragraphs[i].source?.isSame(as: $0) == true }
        })
        guard !languages.isEmpty else { return sessions.isEmpty ? (painted ? onFinished() : onFail()) : () }
        downloads += languages.dropFirst()
        start(languages[0], downloading: true)
        if sessions.isEmpty { painted ? onFinished() : onFail() }
    }

    /// Paragraphs being translated, or translated from what Vision was sure
    /// of: a forced read leaves them be. A guess (0.3) may be read better.
    private var held: [Int] {
        paragraphs.indices.filter { i in
            !dropped.contains(i) && claimed.contains(i)
                && (paragraphs[i].translation.isEmpty || paragraphs[i].lines.allSatisfy { $0.confidence > 0.3 })
        }
    }

    /// A session for this language's paragraphs that no session has taken on yet.
    private func start(_ source: Locale.Language, downloading: Bool = false) {
        let mine = paragraphs.indices.filter {
            !claimed.contains($0) && !dropped.contains($0) && paragraphs[$0].source?.isSame(as: source) == true
        }
        guard !mine.isEmpty else {
            // Nothing left of that language: on to the next download, so the queue never stalls.
            if downloading, !downloads.isEmpty { start(downloads.removeFirst(), downloading: true) }
            return
        }
        claimed.formUnion(mine)
        sessions.append(Session(source: source, paragraphs: mine, downloading: downloading,
                                configuration: .init(source: source, target: target)))
    }

    @MainActor func run(_ session: TranslationSession, for entry: Session) async {
        let focus = focus ?? CGPoint(x: image.width / 2, y: image.height / 2)
        let mine = entry.paragraphs.sorted { Self.distance(paragraphs[$0].box, focus) < Self.distance(paragraphs[$1].box, focus) }
        let requests = mine.map { TranslationSession.Request(sourceText: paragraphs[$0].text, clientIdentifier: "\($0)") }
        // Each paragraph is laid in the moment it's translated.
        do {
            for try await response in session.translate(batch: requests) {
                guard let i = response.clientIdentifier.flatMap(Int.init) else { continue }
                paragraphs[i].translation = response.targetText
                // Every other line shows through: a translation that runs long
                // mustn't paint over its neighbours, translated or not.
                let own = paragraphs[i].lines.map(\.box)
                let others = lines.filter { line in !own.contains { Self.overlap($0, line) > 0.5 } }
                let paragraph = paragraphs[i], painter = painter
                if let patch = await Task.detached(operation: { painter?.patch(i, paragraph, around: others) }).value {
                    painted = true
                    onReady([patch])
                } else {
                    drop([i])  // not paintable (a column over the art): no mark left that never shows anything
                }
            }
        } catch {
            // Declined, or it can't be translated after all: left as it was, free to try again.
            drop(mine.filter { paragraphs[$0].translation.isEmpty })
        }
        if Task.isCancelled { return }
        sessions.removeAll { $0.id == entry.id }
        if entry.downloading, !downloads.isEmpty { return start(downloads.removeFirst(), downloading: true) }
        guard sessions.isEmpty else { return }
        if !missing.isEmpty { return askForMissing() }
        painted ? onFinished() : onFail()
    }

    private func drop(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        dropped.formUnion(ids)
        claimed.subtract(ids)
        onDropped(ids)
    }

    private func askForMissing() {
        let offered = missing
        missing = []
        onMissing(offered)
    }

    /// How much a text says, roughly: a Chinese, Japanese or Korean character counts as two letters.
    private static func weight(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, c in
            sum + ((0x3040...0x30FF).contains(c.value) || (0x4E00...0x9FFF).contains(c.value) || (0xAC00...0xD7A3).contains(c.value) ? 2 : 1)
        }
    }

    private static func distance(_ box: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(max(box.minX - point.x, 0, point.x - box.maxX), max(box.minY - point.y, 0, point.y - box.maxY))
    }

    /// Where the lines of text are, without reading them: a fraction of the time.
    private static func sketch(_ image: CGImage) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { observation in
            let box = VNImageRectForNormalizedRect(observation.boundingBox, image.width, image.height)
            return CGRect(x: box.minX, y: CGFloat(image.height) - box.maxY, width: box.width, height: box.height)
        }
    }

    /// Text lines in pixels, top-left origin. Read whole, Vision misses small
    /// lines (a lone "ん。" ending a sentence, flipping its meaning), so the
    /// screen is then read in four overlapping quarters, all at once, told
    /// which languages the whole read found (left to guess, a quarter took
    /// "ん。" for "ho"), and any line the whole read missed is added.
    /// Text written top to bottom comes from Live Text instead, alongside.
    private static func lines(in image: CGImage) async -> [Line] {
        async let columns = columns(in: image)
        var lines = recognize(image)
        let languages = hints(lines.map(\.text).joined(separator: "\n"))
        let w = image.width / 2, h = image.height / 2, pad = 80
        let tiles = (0..<4).map { i in
            let x = max((i % 2) * w - pad, 0), y = max((i / 2) * h - pad, 0)
            return CGRect(x: x, y: y, width: min(w + 2 * pad, image.width - x), height: min(h + 2 * pad, image.height - y))
        }
        var found = [[Line]](repeating: [], count: tiles.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            guard let crop = image.cropping(to: tiles[i]) else { return }
            let lines = recognize(crop, languages: languages).map {
                Line(text: $0.text, box: $0.box.offsetBy(dx: tiles[i].minX, dy: tiles[i].minY), confidence: $0.confidence)
            }
            lock.lock(); found[i] = lines; lock.unlock()
        }
        for line in found.joined() where !lines.contains(where: { overlap($0.box, line.box) > 0.3 }) {
            lines.append(line)
        }
        return merge(lines, await columns)
    }

    /// Vision's rows, less any Live Text read as a column.
    private static func merge(_ rows: [Line], _ columns: [Line]) -> [Line] {
        rows.filter { row in !columns.contains { overlap($0.box, row.box) > 0.3 } } + columns
    }

    /// Lines written top to bottom (a manga's Japanese), which Vision can't
    /// read but Live Text can. Only Live Text's private lines say where each
    /// one is; should Apple change them, there are none, and Vision's read stands alone.
    private static func columns(in image: CGImage) async -> [Line] {
        func value(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: Selector(key)) ? object.value(forKey: key) : nil
        }
        guard ImageAnalyzer.isSupported,
              let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init([.text])),
              let inner = Mirror(reflecting: analysis).children.first?.value as? NSObject,
              let lines = value(inner, "allLines") as? [NSObject] else { return [] }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return lines.compactMap { line in
            guard let text = value(line, "string") as? String, let quad = value(line, "quad") as? NSObject,
                  let unit = (value(quad, "boundingBox") as? NSValue)?.rectValue else { return nil }
            // A fraction of the image, from its top left.
            let box = CGRect(x: unit.minX * width, y: unit.minY * height, width: unit.width * width, height: unit.height * height)
            // 5 is top to bottom; a short column (ペロペロ) may be called a row, but its shape says otherwise.
            guard value(line, "layoutDirection") as? Int == 5 || text.count > 1 && box.height > box.width * 1.5 else { return nil }
            return Line(text: dashed(text), box: box, vertical: true)
        }
    }

    /// A column trailing off in a dash (したが――) is read as 一, ー, -, | or
    /// even 1, translated as such. After hiragana it can only be the dash;
    /// after kanji it may be a word (世界一), after katakana a long vowel (ハー).
    private static func dashed(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars.suffix(2))
        guard scalars.count == 2, "一ー-1|｜―‐".unicodeScalars.contains(scalars[1]),
              (0x3041...0x309F).contains(scalars[0].value) else { return text }
        return String(text.dropLast()) + "—"
    }

    /// The text's main languages (up to three), as Vision names them; empty if it can't tell.
    private static func hints(_ text: String) -> [String] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        return recognizer.languageHypotheses(withMaximum: 4).filter { $0.value > 0.08 }.sorted { $0.value > $1.value }
            .compactMap { language, _ in
                let code = language.rawValue  // "ja", "zh-Hans"
                return supported.first { $0 == code } ?? supported.first { $0.hasPrefix(code + "-") }
            }
            .prefix(3).map(\.self)
    }

    /// `correct`: the dictionary pass. It triples the time and on a whole
    /// screen only touches up proper nouns, but helps a hard-to-read scrap.
    private static func recognize(_ image: CGImage, correct: Bool = false, languages: [String] = []) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty { request.recognitionLanguages = languages }
        request.usesLanguageCorrection = correct
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = VNImageRectForNormalizedRect(observation.boundingBox, Int(size.width), Int(size.height))
            return Line(text: best.string, box: CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height),
                        confidence: best.confidence)
        }
    }

    /// Twice the size, smoothly: small text reads better.
    private static func enlarged(_ image: CGImage) -> CGImage {
        let big = CIImage(cgImage: image).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2])
        return CIContext().createCGImage(big, from: big.extent) ?? image
    }

    /// Kana are only ever Japanese, but beside Latin the detector all but
    /// ignores them: AnthropicかOpenAiが解決してるだろ comes out Croatian at
    /// 15%, and misread as "Anthropict'OpenAitì 解決してるだろ", surely Italian.
    /// Japanese when its characters say at least half as much as all the
    /// others (Chinese, Japanese and Korean ones two letters' worth each); an
    /// English or Korean sentence quoting ありがとう stays as it is.
    private static func mostlyJapanese(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.contains(where: { (0x3041...0x30FF).contains($0.value) }) else { return false }
        func japanese(_ c: Unicode.Scalar) -> Bool { (0x3041...0x30FF).contains(c.value) || (0x4E00...0x9FFF).contains(c.value) }
        let others = scalars.filter { $0.properties.isAlphabetic && !japanese($0) }.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
        return scalars.filter(japanese).count * 2 * 2 >= others
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

/// A language on screen that isn't downloaded yet, with a sample of the text it was found in.
struct MissingLanguage: Identifiable {
    let language: Locale.Language
    /// Its longest paragraph.
    let sample: String
    let weight: Int
    var id: String { language.maximalIdentifier }
    /// Only scraps (place names on a map, a button) are likely misreads; they start unticked.
    var likely: Bool { weight >= 20 }
}

/// `.translationTask` only runs inside a window; this is the job's.
struct TranslationHost: View {
    let job: SnapJob

    var body: some View {
        ZStack {
            ForEach(job.sessions) { entry in
                Color.clear.translationTask(entry.configuration) { session in await job.run(session, for: entry) }
            }
        }
    }
}

struct Line {
    let text: String
    var box: CGRect
    /// Vision's own: 1 or 0.5 for text it's sure of, 0.3 for its guesses at a scrap.
    var confidence: Float = 1
    /// Written top to bottom: a column.
    var vertical = false

    /// Words, not just digits and marks: two letters' worth, and a fair share of the line.
    /// A Chinese, Japanese or Korean character counts as two: "ん。" ends a sentence.
    var isText: Bool {
        let letters = text.filter(\.isLetter).reduce(0) { sum, c in sum + (c.unicodeScalars.first!.value >= 0x2E80 ? 2 : 1) }
        return letters >= 2 && Double(letters) >= Double(text.filter { !$0.isWhitespace }.count) * 0.3
    }
}

/// Lines that read as one block: stacked closely, about the same size, and
/// overlapping sideways. It's translated as a whole, since a sentence often
/// wraps across lines.
struct Paragraph {
    var lines: [Line]
    var source: Locale.Language?
    var translation = ""

    var box: CGRect { lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) } }
    /// Columns, right to left.
    var vertical: Bool { lines[0].vertical }
    /// The type's size: a line's height, or a column's width.
    var lineHeight: CGFloat { lines.map { vertical ? $0.box.width : $0.box.height }.reduce(0, +) / CGFloat(lines.count) }

    var text: String {
        lines.dropFirst().reduce(lines[0].text) { text, line in
            // Chinese and Japanese don't put spaces where lines wrap.
            let unspaced = text.last?.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) } ?? false
            return text + (unspaced ? "" : " ") + line.text
        }
    }

    static func group(_ lines: [Line]) -> [Paragraph] {
        // Timestamps, ticks and counters ("02:39 ✓✓" read as "02:39 V/") aren't
        // part of the sentence beside them; they're left as they are.
        let lines = lines.filter(\.isText)
        // Columns side by side, right to left, as they're read. A character
        // or two to the left of one (a lone い, read as a row) may end it.
        var columns: [Paragraph] = [], rows = lines.filter { !$0.vertical && $0.text.count > 2 }
        for line in lines.sorted(by: { $0.box.maxX > $1.box.maxX }) where line.vertical || line.text.count <= 2 {
            let i = columns.lastIndex { paragraph in
                let last = paragraph.lines.last!.box
                let gap = last.minX - line.box.maxX
                return gap < last.width * 0.7 && gap > -last.width * 0.3 && (0.6...1.67).contains(line.box.width / last.width)
                    && line.box.minY < last.maxY && last.minY < line.box.maxY
            }
            if let i { columns[i].lines.append(line) } else if line.vertical { columns.append(Paragraph(lines: [line])) } else { rows.append(line) }
        }
        var paragraphs: [Paragraph] = []
        for line in rows.sorted(by: { $0.box.minY < $1.box.minY }) {
            let i = paragraphs.lastIndex { paragraph in
                let last = paragraph.lines.last!.box
                let gap = line.box.minY - last.maxY
                let ratio = line.box.height / last.height
                // Accents and descenders make one line's box taller than the next's.
                return gap < last.height * 0.7 && gap > -last.height * 0.3 && (0.6...1.67).contains(ratio)
                    && line.box.minX < last.maxX && last.minX < line.box.maxX
            }
            if let i { paragraphs[i].lines.append(line) } else { paragraphs.append(Paragraph(lines: [line])) }
        }
        return columns + paragraphs.flatMap(\.items)
    }

    /// A block split where a line stops well short of the others: a list's
    /// items, a heading over its text. A sentence that wraps runs to the edge.
    private var items: [Paragraph] {
        let widest = lines.map(\.box.width).max() ?? 0
        var items: [Paragraph] = [], current: [Line] = []
        for (i, line) in lines.enumerated() {
            current.append(line)
            guard i + 1 < lines.count else { break }
            let next = lines[i + 1].text
            let ends = line.text.last.map { ".!?:;。！？：；)".contains($0) } ?? false
            let starts = next.first.map { $0.isUppercase || $0.isNumber || "•-–—*·(".contains($0) } ?? false
            let bullet = next.range(of: #"^([-•*–·]|\d{1,2}[.)])\s"#, options: .regularExpression) != nil
            let short = line.box.width < widest * 0.8
            if bullet || short && (ends || starts || line.box.width < widest * 0.72) {
                items.append(Paragraph(lines: current))
                current = []
            }
        }
        if !current.isEmpty { items.append(Paragraph(lines: current)) }
        return items
    }
}

/// One paragraph's translation, ready to lay over the original: its box
/// filled with the colour around it and the translation written in the
/// original's text colour. Pixels, top-left origin.
struct Patch: Identifiable {
    let id: Int
    /// Where it's drawn: the paragraph, and any room its translation ran into.
    let box: CGRect
    let image: CGImage
    /// The paragraph it translates, for hovering and dragging.
    let source: CGRect
}

final class Painter {
    private let pixels: Data
    private let width: Int, height: Int

    /// Reads the screen's pixels once, for every paragraph after.
    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.makeImage()?.dataProvider?.data as Data? else { return nil }
        self.pixels = pixels
    }

    private func pixel(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255
    }

    /// `around`: every other line on screen; any the patch would cover shows through it.
    func patch(_ id: Int, _ paragraph: Paragraph, around: [CGRect] = []) -> Patch? {
        guard !paragraph.translation.isEmpty else { return nil }
        let lines = paragraph.lines
        let lineHeight = paragraph.lineHeight
        let pad = (lineHeight * 0.2).rounded()
        let pitch = lines.count < 2 ? lineHeight * 1.3
            : paragraph.vertical ? (lines[0].box.maxX - lines.last!.box.maxX) / CGFloat(lines.count - 1)
            : (lines.last!.box.minY - lines[0].box.minY) / CGFloat(lines.count - 1)
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        // Halfway into the space between lines: a highlight's edge doesn't peek
        // out between paragraphs, and neighbours meet without overlapping.
        let between = max(2, (pitch - lineHeight) / 2)
        let covered = paragraph.box.insetBy(dx: paragraph.vertical ? -between : -pad, dy: paragraph.vertical ? -pad : -between)
            .intersection(whole).integral
        // The background: the most common colour on the box's edge.
        var edge: [SIMD3<Double>] = []
        for x in stride(from: Int(covered.minX), to: Int(covered.maxX), by: 2) { edge += [pixel(x, Int(covered.minY)), pixel(x, Int(covered.maxY) - 1)] }
        for y in stride(from: Int(covered.minY), to: Int(covered.maxY), by: 2) { edge += [pixel(Int(covered.minX), y), pixel(Int(covered.maxX) - 1, y)] }
        let background = Self.mode(edge)
        // The text: the inside pixels least like the background; how much of
        // the lines it covers says how heavy the type is.
        var inside: [SIMD3<Double>] = []
        for line in lines {
            for y in stride(from: Int(line.box.minY), to: Int(line.box.maxY), by: 2) {
                for x in stride(from: Int(line.box.minX), to: Int(line.box.maxX), by: 2) { inside.append(pixel(x, y)) }
            }
        }
        let far = inside.sorted { Self.distance($0, background) > Self.distance($1, background) }.prefix(max(1, inside.count / 20))
        var ink = far.reduce(.zero, +) / Double(far.count)
        let contrast = Self.distance(ink, background)
        if contrast < 0.3 { ink = Self.luminance(background) > 0.5 ? .zero : .one }
        // How heavy the type is: the strokes' width across the middle of each
        // line, less the pixel antialiasing adds, against the line's height.
        // The longest tenth is left out: a highlight or underline isn't a stroke.
        var runs: [Int] = []
        for line in lines {
            for y in stride(from: Int(line.box.minY + line.box.height * 0.3), to: Int(line.box.maxY - line.box.height * 0.3), by: 1) {
                var run = 0
                for x in Int(line.box.minX)...Int(line.box.maxX) {
                    if x < Int(line.box.maxX), Self.distance(pixel(x, y), background) > contrast * 0.5 { run += 1; continue }
                    if run > 0 { runs.append(run) }
                    run = 0
                }
            }
        }
        let kept = runs.sorted().prefix(max(1, runs.count * 9 / 10))
        let stroke = (Double(kept.reduce(0, +)) / Double(max(kept.count, 1)) - 1) / lineHeight
        let weight: NSFont.Weight = stroke > 0.13 ? .bold : stroke > 0.087 ? .semibold : .regular
        if paragraph.vertical {
            // Drawn over the picture itself (a cry beside a face), it isn't covered: a box would hide the art.
            guard edge.filter({ Self.distance($0, background) < 0.12 }).count * 10 >= edge.count * 6 else { return nil }
            return across(id, paragraph, covered: covered, background: background, ink: ink, weight: weight, around: around)
        }

        // Laid out like the original: same left edge, same first line, same
        // line spacing, the same size type; centred only if the original was.
        let lefts = lines.map(\.box.minX), middles = lines.map(\.box.midX)
        let centred = lines.count > 1 && (lefts.max()! - lefts.min()!) > lineHeight * 0.5 && (middles.max()! - middles.min()!) < lineHeight * 0.4
        // Room to the right where the background carries on, for a translation that runs longer.
        var right = covered.maxX
        let rows = lines.map { Int($0.box.midY) }
        while right < covered.maxX + paragraph.box.width * 0.5, right < CGFloat(width - 1),
              rows.allSatisfy({ Self.distance(pixel(Int(right), $0), background) < 0.08 }) { right += 1 }
        right = centred ? covered.maxX : max(covered.maxX, right - pad)
        // And below, up to two more lines, before the type shrinks.
        var below = covered.maxY
        let columns = stride(from: Int(paragraph.box.minX), to: Int(right), by: 4).map { $0 }
        while below < covered.maxY + pitch * 2, below < CGFloat(height - 1),
              columns.allSatisfy({ Self.distance(pixel($0, Int(below)), background) < 0.08 }) { below += 1 }
        let roomBelow = max(0, below - covered.maxY - pitch * 0.4)
        let column = CGRect(x: paragraph.box.minX, y: lines[0].box.minY, width: right - pad - paragraph.box.minX,
                            height: max(paragraph.box.height, CGFloat(lines.count) * pitch) + roomBelow)

        // Vision's boxes run about a Latin font's size, but taller than a Chinese or Japanese one.
        let dense = paragraph.text.unicodeScalars.filter { $0.value >= 0x2E80 }.count * 2 > paragraph.text.count
        var size = lineHeight * (dense ? 0.87 : 0.88), text = NSAttributedString(), used = CGRect.zero, spacing: CGFloat = 0
        repeat {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineBreakStrategy = .hangulWordPriority  // Korean breaks between words, not syllables
            style.alignment = centred ? .center : .left
            spacing = max(0, pitch - (font.ascender - font.descender + font.leading))
            style.lineSpacing = spacing
            text = NSAttributedString(string: paragraph.translation, attributes: [.font: font, .foregroundColor: Self.color(ink), .paragraphStyle: style])
            used = text.boundingRect(with: CGSize(width: column.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            size *= 0.94
        } while used.height > column.height + lineHeight * 0.1 && size > lineHeight * 0.5  // never into the next paragraph
        // The first line sits where the original's did.
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let top = lines[0].box.minY + (lineHeight - (font.ascender - font.descender)) / 2
        let frame = CGRect(x: column.minX, y: top, width: column.width, height: ceil(used.height))
        // The ink, not the spacing after the last line, decides how far down a long translation reaches.
        let inked = CGRect(x: frame.minX - pad, y: frame.minY, width: frame.width + pad * 2, height: max(0, frame.height - spacing))
        let box = covered.union(inked).intersection(whole).integral
        // Only where the translation ran past its own paragraph: at the border
        // two neighbours meet halfway, and holes there would leave a gap both ways.
        let others = around.filter { box.intersects($0) && !covered.intersects($0) }
            .map { $0.insetBy(dx: -1, dy: -1).offsetBy(dx: -box.minX, dy: -box.minY) }
        guard let image = Self.render(text, in: frame.offsetBy(dx: -box.minX, dy: -box.minY), size: box.size,
                                      background: Self.color(background), holes: others) else { return nil }
        return Patch(id: id, box: box, image: image, source: paragraph.box)
    }

    /// Columns translated into rows, centred where the columns stood. Rows need
    /// longer lines, so the box widens while the background carries on (a
    /// speech bubble's white), judged across its middle: a bubble narrows at the ends.
    private func across(_ id: Int, _ paragraph: Paragraph, covered: CGRect, background: SIMD3<Double>, ink: SIMD3<Double>,
                        weight: NSFont.Weight, around: [CGRect]) -> Patch? {
        let size = paragraph.lineHeight, pad = (size * 0.2).rounded()
        let rows = stride(from: Int(covered.minY + covered.height * 0.15), to: Int(covered.maxY - covered.height * 0.15), by: 4).map { $0 }
        let reach = covered.height * 0.4
        var left = covered.minX, right = covered.maxX
        while left > max(covered.minX - reach, 1), rows.allSatisfy({ Self.distance(pixel(Int(left) - 1, $0), background) < 0.08 }) { left -= 1 }
        while right < min(covered.maxX + reach, CGFloat(width - 1)), rows.allSatisfy({ Self.distance(pixel(Int(right), $0), background) < 0.08 }) { right += 1 }
        let column = CGRect(x: left + pad, y: covered.minY + pad, width: max(right - left - pad * 2, size), height: covered.height - pad * 2)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .hangulWordPriority
        style.alignment = .center
        // Spaced words mustn't break mid-word; Chinese and Japanese break anywhere.
        let words = paragraph.translation.split(whereSeparator: \.isWhitespace)
            .filter { !$0.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) } }
        var points = size * 0.87, text = NSAttributedString(), used = CGRect.zero, fits = false
        repeat {
            let font = NSFont.systemFont(ofSize: points, weight: weight)
            text = NSAttributedString(string: paragraph.translation, attributes: [.font: font, .foregroundColor: Self.color(ink), .paragraphStyle: style])
            used = text.boundingRect(with: CGSize(width: column.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            let widest = words.map { NSAttributedString(string: String($0), attributes: [.font: font]).size().width }.max() ?? 0
            fits = used.height <= column.height && widest <= column.width
            points *= 0.94
        } while !fits && points > size * 0.4
        let frame = CGRect(x: column.minX, y: column.midY - ceil(used.height) / 2, width: column.width, height: ceil(used.height))
        // Widened only as far down as the rows reach, short of a bubble's narrowing ends:
        // the corners beside the columns, above and below the rows, show through.
        let band = frame.insetBy(dx: -pad, dy: -pad)
        let box = covered.union(band).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        let corners = [(box.minX, covered.minX), (covered.maxX, box.maxX)].flatMap { x in
            [(box.minY, band.minY), (band.maxY, box.maxY)].map { y in CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0) }
        }
        let others = (around.filter { box.intersects($0) && !covered.intersects($0) }.map { $0.insetBy(dx: -1, dy: -1) } + corners)
            .filter { $0.width > 0 && $0.height > 0 }
            .map { $0.offsetBy(dx: -box.minX, dy: -box.minY) }
        guard let image = Self.render(text, in: frame.offsetBy(dx: -box.minX, dy: -box.minY), size: box.size,
                                      background: Self.color(background), holes: others) else { return nil }
        return Patch(id: id, box: box, image: image, source: paragraph.box)
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

    private static func render(_ text: NSAttributedString, in frame: CGRect, size: CGSize, background: NSColor, holes: [CGRect]) -> CGImage? {
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
        context.setAllowsFontSmoothing(false)  // as macOS draws text on screen; smoothing thickens it
        text.draw(with: frame, options: [.usesLineFragmentOrigin])
        for hole in holes { context.clear(hole) }  // the original shows through
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func mode(_ colors: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !colors.isEmpty else { return .one }
        // Bucket into 4-bit channels so anti-aliasing noise falls together.
        let common = Dictionary(grouping: colors) { ($0 * 15).rounded(.toNearestOrEven) }.values.max { $0.count < $1.count }!
        return common.reduce(.zero, +) / Double(common.count)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        return shared.width * shared.height / max(min(a.width * a.height, b.width * b.height), 1)
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
