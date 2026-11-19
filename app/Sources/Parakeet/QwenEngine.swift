import Foundation
import MLX
import MLXAudioSTT

/// Qwen3-ASR 1.7B (8-bit, MLX on the GPU), streamed the way Qwen's own
/// toolkit does it: every second the whole utterance so far is transcribed
/// again, with the previous answer minus its last few tokens forced as the
/// start. Those forced tokens never change again, so sentences inside them
/// are locked as finals; the last few tokens show as a partial. A second
/// that adds no words ends the utterance. Used by the "--engine qwen"
/// debug build.
final class QwenEngine: Engine {
    static let repo = "mlx-community/Qwen3-ASR-1.7B-8bit"
    private static let chunk = 16_000             // 1 s of new audio per pass, at least
    private static let rollback = 5               // tokens re-decoded each pass (Qwen's unfixed_token_num)
    private static let freshPasses = 2            // passes before the answer is reused (unfixed_chunk_num)
    private static let longest = 30 * 16_000      // an utterance is cut here regardless
    private static let eos: Set<Int> = [151645, 151643]

    private let lock = NSLock()
    private var incoming: [Float] = []
    private var task: Task<Void, Never>?

    /// `rehearseFirstLaunch` plays a fake model download and the first-time
    /// preparation pause before loading the real (cached) model.
    init(rehearseFirstLaunch: Bool = false, onEvent: @escaping (EngineEvent) -> Void) {
        let emit = { (event: EngineEvent) in DispatchQueue.main.async { onEvent(event) } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if rehearseFirstLaunch {
                    for percent in 0...100 {
                        emit(.downloading(Double(percent) / 100))
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                // mlx-audio-swift reports no download progress; the first
                // load shows "preparing" through the ~2 GB download.
                emit(.preparing)
                let model = try await Qwen3ASRModel.fromPretrained(Self.repo)
                emit(.ready)
                try await self?.run(model, emit: emit)
            } catch is CancellationError {
            } catch {
                emit(.exited(error.localizedDescription))
            }
        }
    }

    func send(_ pcm: Data) {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        lock.withLock { incoming.append(contentsOf: samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }) }
    }

    func stop() { task?.cancel() }

    private func run(_ model: Qwen3ASRModel, emit: @escaping (EngineEvent) -> Void) async throws {
        guard let tokenizer = model.tokenizer else { throw CocoaError(.fileReadCorruptFile) }
        let text = { (tokens: ArraySlice<Int>) in Self.transcript(tokenizer.decode(tokens: Array(tokens))) }
        var pending: [Float] = []
        var audio: [Float] = []   // the utterance so far
        var tokens: [Int] = []    // its answer, language tag included
        var passes = 0
        var committed = 0         // characters of the answer already locked in
        var shown = ""

        func endUtterance() {
            let rest = String(text(tokens[...]).dropFirst(committed)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { emit(Self.locked(rest)) }
            audio = []; tokens = []; passes = 0; committed = 0; shown = ""
        }

        while !Task.isCancelled {
            pending += lock.withLock { () -> [Float] in
                defer { incoming.removeAll(keepingCapacity: true) }
                return incoming
            }
            guard pending.count >= Self.chunk else {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            // A pass that fell behind takes every whole second waiting.
            let taken = pending.count / Self.chunk * Self.chunk
            let samples = pending.prefix(taken)
            pending.removeFirst(taken)
            // Digital silence between utterances: skip the model.
            if audio.isEmpty, !samples.contains(where: { abs($0) > 1e-4 }) { continue }
            audio += samples

            let before = text(tokens[...])
            let forced = passes < Self.freshPasses ? [] : Array(tokens.dropLast(Self.rollback))
            tokens = forced + Self.decode(model, audio: audio, after: forced)
            passes += 1
            let all = text(tokens[...])

            // The forced part is fixed for the rest of the utterance; lock
            // its finished sentences.
            if passes > Self.freshPasses {
                let fixed = text(tokens.dropLast(Self.rollback)).dropFirst(committed)
                if let end = Self.lastSentenceEnd(in: fixed) {
                    emit(Self.locked(fixed[..<end].trimmingCharacters(in: .whitespaces)))
                    committed += fixed.distance(from: fixed.startIndex, to: end)
                }
            }

            if passes > 1, all == before || audio.count >= Self.longest {
                endUtterance()  // a second with no new words, or too long
            } else if all.isEmpty, audio.count >= 5 * 16_000 {
                audio = []; tokens = []; passes = 0  // sound but no speech
            } else {
                let now = String(all.dropFirst(committed)).trimmingCharacters(in: .whitespaces)
                if now != shown {
                    shown = now
                    emit(.partial(now))
                }
            }
        }
    }

    /// Greedy answer for `audio`, continuing from the forced `after` tokens.
    private static func decode(_ model: Qwen3ASRModel, audio: [Float], after forced: [Int]) -> [Int] {
        let (features, mask, audioTokens) = model.preprocessAudio(MLXArray(audio))
        var ids = model.buildPrompt(numAudioTokens: audioTokens)
        if !forced.isEmpty {
            ids = concatenated([ids, MLXArray(forced.map(Int32.init)).expandedDimensions(axis: 0)], axis: 1)
        }
        let cache = model.makeCache()
        var logits = model(inputIds: ids, inputFeatures: features, featureAttentionMask: mask, cache: cache)
        var out: [Int] = []
        for _ in 0..<64 {
            let next = logits[0..., -1, 0...].argMax(axis: -1).item(Int.self)
            if eos.contains(next) { break }
            out.append(next)
            logits = model(inputIds: MLXArray([Int32(next)]).expandedDimensions(axis: 0), cache: cache)
        }
        Memory.clearCache()
        return out
    }

    /// The answer without its leading "language <Name><asr_text>" (also
    /// while that is still being generated) and without a character whose
    /// bytes are split across tokens (U+FFFD until its last byte).
    private static func transcript(_ decoded: String) -> String {
        var text = decoded
        if let tag = text.range(of: #"^\s*language\s+[^<\s]*\s*<asr_text>"#, options: .regularExpression) {
            text = String(text[tag.upperBound...])
        } else if text.range(of: #"^\s*language(\s+[^<\s]*)?\s*(<[a-z_]*)?$"#, options: .regularExpression) != nil {
            text = ""
        }
        return text.replacingOccurrences(of: "\u{FFFD}", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func locked(_ text: String) -> EngineEvent {
        text.last.map { ".?!。？！".contains($0) } == true ? .final(text) : .fragment(text)
    }

    /// Just past the last sentence end followed by more text ("fast. The",
    /// not "3.5"), or a CJK sentence end anywhere.
    private static func lastSentenceEnd(in text: Substring) -> String.Index? {
        for mark in text.indices.reversed() where ".?!。？！".contains(text[mark]) {
            let after = text.index(after: mark)
            if "。？！".contains(text[mark]) { return after }
            if after < text.endIndex, text[after] == " " { return after }
        }
        return nil
    }
}
