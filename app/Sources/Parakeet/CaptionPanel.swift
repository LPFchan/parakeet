import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// One continuous run of text per burst of speech. New characters type in
/// a few at a time instead of popping in, so the eye can follow them.
@Observable
final class Captions {
    private(set) var transcript: [String] = []
    private(set) var locked = ""
    private(set) var partial = ""
    private(set) var revealed = 0
    private var lastUpdate = Date()
    @ObservationIgnored private var ticker: Timer?

    var isEmpty: Bool { locked.isEmpty && partial.isEmpty }
    private var target: Int { full.count }
    private var full: String { locked.isEmpty || partial.isEmpty ? locked + partial : locked + " " + partial }

    /// The typed-in part, split into locked (bright) and still-changing (dim).
    var visible: (locked: String, partial: String) {
        let shown = String(full.prefix(revealed))
        let split = min(shown.count, locked.count)
        return (String(shown.prefix(split)), String(shown.dropFirst(split)))
    }

    func lock(_ text: String) {
        // Streaming models can deliver a sentence's full stop after the pause.
        let attaches = text.first.map { ".,?!。、？！".contains($0) } ?? false
        if attaches, !transcript.isEmpty { transcript[transcript.count - 1] += text } else { transcript.append(text) }
        if transcript.count > 5000 { transcript.removeFirst() }  // hours of speech; the app runs for weeks
        // Japanese and Chinese don't put spaces between sentences (Korean does).
        let unspaced = locked.last?.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) } ?? false
        locked = locked.isEmpty ? text : locked + (attaches || unspaced ? "" : " ") + text
        // Only ~3 lines are on screen; text above them has scrolled out of view,
        // and laying it out again on every typed character is what costs CPU.
        if locked.count > 400 {
            let drop = locked.count - 300
            let cut = locked.index(locked.startIndex, offsetBy: drop)
            let wordStart = locked[cut...].firstIndex(of: " ").map { locked.index(after: $0) } ?? cut
            revealed = max(0, revealed - locked.distance(from: locked.startIndex, to: wordStart))
            locked = String(locked[wordStart...])
        }
        partial = ""
        changed()
    }

    func update(_ text: String) {
        partial = text
        changed()
    }

    /// Seconds since the text last changed, while nothing more is on its way.
    var idle: TimeInterval { partial.isEmpty ? Date().timeIntervalSince(lastUpdate) : 0 }

    func clear() {
        guard !isEmpty else { return }
        locked = ""
        partial = ""
        revealed = 0
    }

    private func changed() {
        lastUpdate = .now
        revealed = min(revealed, target)
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let remaining = target - revealed
            if remaining <= 0 { timer.invalidate(); ticker = nil; return }
            // Close the gap in ~150 ms whatever its size, but never jump a whole word at once.
            revealed += min(max(1, remaining / 5), 6)
        }
    }
}

/// Translates each locked sentence into its own caption stream, shown above
/// the original. Sentences already in the target language pass through, and
/// so does speech in a language that isn't downloaded: it's offered for
/// download once it's clearly what's being spoken.
@Observable
final class Translator {
    let output = Captions()
    var target = UserDefaults.standard.string(forKey: "translateTo").map(Locale.Language.init(identifier:)) {
        didSet {
            UserDefaults.standard.set(target?.minimalIdentifier, forKey: "translateTo")
            queue.removeAll(); draft = ""; output.clear(); hearingNative = false
            known = [:]; heardLately = []; offer = nil
        }
    }
    /// The language translated into is taken as the user's own: while the
    /// speech is in it, there is nothing to caption and the box hides.
    private(set) var hearingNative = false
    /// The speech is in a language that can't be translated (yet): the box
    /// shows it as heard, large, as with translation off.
    private(set) var passing = false
    /// A language heard clearly but not downloaded, offered under the box.
    private(set) var offer: Locale.Language?
    /// What Translation can translate into, by name.
    private(set) var languages: [Locale.Language] = []
    /// The language being heard, when it's downloaded. Translation needs it
    /// spelled out: left to detect it, the framework stops to ask the user.
    private var source: Locale.Language?
    /// The language being spoken, downloaded or not.
    @ObservationIgnored private var speech: Locale.LanguageCode?
    /// Downloaded, or not translatable at all, by language heard. Ones that could be
    /// downloaded are asked again each time: a download may finish any moment.
    @ObservationIgnored private var known: [Locale.LanguageCode: LanguageAvailability.Status] = [:]
    /// Offered once a launch: turned down, or handed to macOS to download.
    @ObservationIgnored private var asked: Set<Locale.LanguageCode> = []
    /// Recent speech in languages that aren't downloaded, for judging whether
    /// one is really being spoken or was a misheard scrap.
    @ObservationIgnored private var heardLately: [(at: Date, language: Locale.LanguageCode, weight: Int)] = []
    /// Shows macOS's download prompt; the caption panel sets it.
    @ObservationIgnored var ask: (_ source: Locale.Language, _ target: Locale.Language) -> Void = { _, _ in }
    @ObservationIgnored private var queue: [(text: String, ends: Bool)] = []
    /// The unfinished sentence so far. A piece cut from it mid-sentence
    /// translates badly on its own, so each new piece re-translates all of it:
    /// shown dim until the sentence ends, then locked.
    @ObservationIgnored private var draft = ""
    @ObservationIgnored private var lastPiece = Date()
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?

    init() {
        Task { @MainActor in
            languages = await LanguageAvailability().supportedLanguages.sorted { Self.name($0) < Self.name($1) }
        }
    }

    static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    /// Drives `.translationTask`, which restarts `run` when either language changes.
    var configuration: TranslationSession.Configuration? { target.map { .init(source: source, target: $0) } }

    func translate(_ text: String, ends: Bool) {
        guard target != nil else { return }
        queue.append((text, ends))
        wake?.yield()
    }

    /// Works through the queue, one sentence at a time and in order. On the
    /// main actor: the captions it feeds are UI state, typed in by a main-thread timer.
    @MainActor func run(_ session: TranslationSession) async {
        let (signals, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        wake.yield()  // anything queued while the session was starting
        for await _ in signals {
            while let (piece, ends) = queue.first {
                let text = draft.isEmpty ? piece : draft + " " + piece
                let heard = Self.language(of: text, leaning: speech.map { Locale.Language(languageCode: $0) })
                if heard == target?.languageCode {  // hidden anyway; nothing to show
                    queue.removeFirst()
                    draft = ""
                    output.clear()
                    continue
                }
                if let heard { speech = heard }
                // Nothing heard clearly yet: show it as heard.
                guard let speech else { pass(); continue }
                if speech != source?.languageCode {
                    // Never a session for a language that isn't downloaded: macOS would
                    // stop to ask about it on every switch, or (when it can't show
                    // its prompt) wait for an answer forever, translating nothing more.
                    let status = await status(of: speech)
                    if Task.isCancelled { return }
                    if status == .installed {
                        source = Locale.Language(languageCode: speech)  // a session for the new language picks it up
                        return
                    }
                    pass()
                    if status == .supported { consider(speech, piece) }
                    continue
                }
                passing = false
                let result = try? await session.translate(text)
                if Task.isCancelled { return }  // keep it queued for the next session
                queue.removeFirst()
                lastPiece = .now
                // Ends the sentence, or it has run on for long enough (no punctuation at all).
                if ends || text.count > 400 {
                    draft = ""
                    output.lock(result?.targetText ?? text)
                } else {
                    draft = text
                    output.update(result?.targetText ?? text)
                }
            }
        }
    }

    /// Shows the front of the queue as heard instead of translating it.
    private func pass() {
        queue.removeFirst()
        draft = ""
        output.clear()
        passing = true
    }

    private func status(of language: Locale.LanguageCode) async -> LanguageAvailability.Status? {
        guard let target else { return nil }
        if let status = known[language] { return status }
        let status = await LanguageAvailability().status(from: Locale.Language(languageCode: language), to: target)
        if status != .supported { known[language] = status }
        return status
    }

    /// Offers a language once it's clearly being spoken: two pieces of it,
    /// sure of it each time, about two sentences' worth within half a minute.
    /// A misheard scrap now and then never adds up to that.
    private func consider(_ language: Locale.LanguageCode, _ piece: String) {
        guard offer == nil, !asked.contains(language),
              Self.language(of: piece, confidence: 0.8) == language else { return }
        heardLately.removeAll { $0.at < Date(timeIntervalSinceNow: -30) }
        heardLately.append((.now, language, SnapJob.weight(piece)))
        let mine = heardLately.filter { $0.language == language }
        guard mine.count >= 2, mine.map(\.weight).reduce(0, +) >= 80 else { return }
        heardLately.removeAll()
        offer = Locale.Language(languageCode: language)
    }

    /// Asked once a launch, either way.
    func decline() {
        if let language = offer?.languageCode { asked.insert(language) }
        offer = nil
    }

    /// macOS asks for permission, then downloads it; until it's in, the speech still shows as heard.
    func download() {
        guard let language = offer, let code = language.languageCode, let target else { return }
        asked.insert(code)
        offer = nil
        ask(language, target)
    }

    /// Nobody's speaking: an offer nobody answered goes with the captions.
    func quiet() { offer = nil }

    /// A sentence that stopped without its full stop: lock its draft once
    /// nothing more has come for a while.
    func settle(after seconds: TimeInterval) {
        guard !draft.isEmpty, queue.isEmpty, Date().timeIntervalSince(lastPiece) > seconds else { return }
        draft = ""
        output.lock(output.partial)
    }

    /// Follows the speech, live text included, so the box hides as soon as it
    /// turns native and comes back when it doesn't. Returns whether it switched.
    func hear(_ text: String) -> Bool {
        guard target != nil, text.count >= 12,
              let heard = Self.language(of: text, confidence: 0.8) else { return false }
        let native = heard == target?.languageCode
        guard native != hearingNative else { return false }
        hearingNative = native
        output.clear()
        return true
    }

    /// Short fragments are ambiguous, so this leans toward the language already
    /// being heard and only switches on a confident guess.
    private static func language(of text: String, leaning toward: Locale.Language? = nil, confidence: Double = 0.6) -> Locale.LanguageCode? {
        let recognizer = NLLanguageRecognizer()
        if let code = toward?.languageCode?.identifier { recognizer.languageHints = [NLLanguage(rawValue: code): 0.8] }
        recognizer.processString(text)
        guard let (language, sure) = recognizer.languageHypotheses(withMaximum: 1).first, sure >= confidence else { return nil }
        return Locale.Language(identifier: language.rawValue).languageCode
    }
}

/// macOS asks before downloading a language, in a prompt that hangs off a
/// window of the app in front. The caption box is never in front (it mustn't
/// take the keyboard), so this comes forward just to ask, and goes once it's answered.
final class DownloadPrompt: NSPanel {
    private let previous = NSWorkspace.shared.frontmostApplication

    init(source: Locale.Language, target: Locale.Language, at point: CGPoint, done: @escaping () -> Void) {
        super.init(contentRect: CGRect(origin: point, size: CGSize(width: 1, height: 1)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: DownloadHost(configuration: .init(source: source, target: target)) { [weak self] in
            self?.finish()
            done()
        })
        makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    override var canBecomeKey: Bool { true }

    private func finish() {
        orderOut(nil)
        contentView = nil
        if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate() }
    }
}

private struct DownloadHost: View {
    let configuration: TranslationSession.Configuration
    let done: () -> Void

    var body: some View {
        // Turned down, it throws; either way the answer is in.
        Color.clear.translationTask(configuration) { session in
            try? await session.prepareTranslation()
            done()
        }
    }
}

/// A floating, draggable caption box that stays above
/// other windows, including full-screen apps.
final class CaptionPanel: NSPanel {
    init(captions: Captions, translator: Translator, onClose: @escaping () -> Void, onCopy: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let width = min(900, screen.width * 0.7)
        let height = 150 + CaptionView.offerHeight
        setFrame(.init(x: screen.midX - width / 2, y: screen.minY + 60 - CaptionView.offerHeight, width: width, height: height), display: false)
        setFrameAutosaveName("Captions")  // remember where it was dragged to
        // Saved before there was room under the box for a download offer: grow
        // it downward, so the box stays where it was put.
        if frame.height < height {
            setFrame(.init(x: frame.minX, y: frame.minY - (height - frame.height), width: frame.width, height: height), display: false)
        }
        translator.ask = { [weak self] source, target in
            guard let self else { return }
            prompt = DownloadPrompt(source: source, target: target, at: CGPoint(x: frame.midX, y: frame.minY + CaptionView.offerHeight)) { [weak self] in
                self?.prompt = nil
            }
        }

        let host = NSHostingView(rootView: CaptionView(captions: captions, translator: translator, onClose: onClose, onCopy: onCopy))
        host.sizingOptions = []
        contentView = host
    }

    private var prompt: DownloadPrompt?

    override var canBecomeKey: Bool { false }
}

struct CaptionView: View {
    let captions: Captions
    var translator: Translator?
    /// The buttons show only when both are given (not in the welcome window's preview).
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    @State private var hovering = false

    /// Room under the box for a download offer, kept even when there's none so the box never moves.
    static let offerHeight: CGFloat = 46

    // Speech that can't be translated shows as with translation off.
    private var translation: Captions? { translator?.target == nil || translator?.passing == true ? nil : translator?.output }
    private var isEmpty: Bool { captions.isEmpty && translation?.isEmpty ?? true }
    // Your own language hides the box whenever a target is picked, translating or passing through.
    private var shown: Bool { !isEmpty && !(translator?.target != nil && translator?.hearingNative == true) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if shown {
                HStack(alignment: .center, spacing: 14) {
                    // Translating: the translation large on top, the original live below.
                    VStack(spacing: 6) {
                        if let translation {
                            CaptionText(captions: translation, size: 22, lines: 2, opacity: 1)
                            CaptionText(captions: captions, size: 15, lines: 2, opacity: 0.7)
                        } else {
                            CaptionText(captions: captions, size: 22, lines: 3, opacity: 1)
                        }
                    }
                    if let onClose, let onCopy, let translator {
                        VStack(spacing: 12) {
                            GlyphButton("xmark", help: "Turn Captions Off", action: onClose)
                            GlyphButton("doc.on.doc", help: "Copy Transcript", action: onCopy)
                            Menu {
                                // By short code: the list has "ko-KR" where the saved choice is "ko".
                                Picker("Translate To", selection: Binding(
                                    get: { translator.target?.minimalIdentifier },
                                    set: { translator.target = $0.map(Locale.Language.init(identifier:)) })) {
                                    Text("Off").tag(String?.none)
                                    ForEach(translator.languages, id: \.self) { Text(Translator.name($0)).tag(Optional($0.minimalIdentifier)) }
                                }
                                .pickerStyle(.inline)
                            } label: {
                                Glyph("translate")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Translate To")
                        }
                        // Only while the pointer is over the box; the space stays, so text doesn't reflow.
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: hovering)
                    }
                }
                .onHover { hovering = $0 }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: 14))
                .transition(.opacity)
            }
            if onClose != nil, let translator {
                ZStack {
                    if shown, let language = translator.offer {
                        DownloadOffer(language: language, decline: translator.decline, download: translator.download)
                            .transition(.opacity.combined(with: .offset(y: -8)))
                    }
                }
                .frame(height: Self.offerHeight, alignment: .bottom)
                .animation(.spring(duration: 0.34, bounce: 0), value: shown ? translator.offer : nil)
            }
        }
        .animation(.easeOut(duration: 0.3), value: shown)
        .translationTask(translator?.configuration) { session in await translator?.run(session) }
    }
}

/// Asks whether to download the language being spoken, in ⇧⌘1's words and
/// look; macOS asks for permission after.
private struct DownloadOffer: View {
    let language: Locale.Language
    let decline: () -> Void
    let download: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Text("Download \(Translator.name(language)) to translate?").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            Button("Not Now", action: decline)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 6)
            Button("Download", action: download)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(Pill())
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// Text that grows upward from the bottom edge; the frame clips it and fades
/// out the top line, so wrapping reads as a scroll.
private struct CaptionText: View {
    let captions: Captions
    let size: CGFloat
    let lines: CGFloat
    let opacity: Double
    @State private var lift: CGFloat = 0
    private var lineHeight: CGFloat { (size * 1.19).rounded() }  // SF and Korean; CJK sets tighter
    private var fade: CGFloat { (lineHeight * 0.3).rounded() }

    var body: some View {
        let visible = captions.visible
        (Text(visible.locked).foregroundStyle(.white.opacity(opacity))
         + Text(visible.partial).foregroundStyle(.white.opacity(opacity * 0.6)))
            .font(.system(size: size, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // When a new line wraps in, start it one line lower and glide
            // up. Only the offset animates, so the text isn't re-laid out
            // every frame (animating the text itself cost ~90% CPU).
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { old, new in
                guard new > old else { return }
                lift += new - old
                withAnimation(.easeOut(duration: 0.25)) { lift = 0 }
            }
            .offset(y: lift)
            // Exactly `lines` lines, plus a strip above them where the line
            // scrolling out fades away; the lines themselves stay crisp.
            .frame(height: lineHeight * lines + fade, alignment: .bottom)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: fade / (lineHeight * lines + fade))], startPoint: .top, endPoint: .bottom))
    }
}

private struct Glyph: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 22, height: 22)
            .contentShape(.rect)
    }
}

private struct GlyphButton: View {
    let name: String
    let help: LocalizedStringKey
    let action: () -> Void
    init(_ name: String, help: LocalizedStringKey, action: @escaping () -> Void) { self.name = name; self.help = help; self.action = action }

    var body: some View {
        Button(action: action) { Glyph(name) }
            .buttonStyle(.plain)
            .help(help)
    }
}
