import AppKit
import SwiftUI

/// First-launch wizard: what Parakeet does, the audio permission, the model
/// download, Screen Recording for ⇧⌘1 (optional), and where to find it afterwards.
@Observable
final class Onboarding {
    enum Step: Int, CaseIterable { case welcome, permission, model, screen, done }
    enum ModelState: Equatable { case waiting, downloading(Double), preparing, ready, failed(String) }

    var step = Step.welcome
    var model = ModelState.waiting
    var permission = AudioPermission.status
    var openAtLogin = true
    var screenAllowed = CGPreflightScreenCaptureAccess()
    @ObservationIgnored var onFinish: () -> Void = {}
    /// Saves what's been set up so far, before macOS may ask to quit and reopen Parakeet.
    @ObservationIgnored var onScreenRecording: () -> Void = {}
    @ObservationIgnored var onRetry: () -> Void = {}
}

final class OnboardingWindow: NSWindow, NSWindowDelegate {
    private let onboarding: Onboarding

    init(_ onboarding: Onboarding) {
        self.onboarding = onboarding
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self
        contentView = NSHostingView(rootView: OnboardingView(onboarding: onboarding))
        center()
    }

    // Closing it early counts as done: captions start once the model is ready.
    func windowWillClose(_ notification: Notification) { onboarding.onFinish() }
}

private let green = Color(red: 0.13, green: 0.60, blue: 0.37)

private struct OnboardingView: View {
    @Bindable var onboarding: Onboarding

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch onboarding.step {
                case .welcome: WelcomeStep()
                case .permission: PermissionStep(onboarding: onboarding)
                case .model: ModelStep(state: onboarding.model)
                case .screen: ScreenStep(onboarding: onboarding)
                case .done: DoneStep(openAtLogin: $onboarding.openAtLogin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 52)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(onboarding.step)

            primaryButton
            HStack(spacing: 8) {
                ForEach(Onboarding.Step.allCases, id: \.self) { step in
                    Circle().fill(step == onboarding.step ? green : .secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .frame(width: 640, height: 600)
        .background {
            LinearGradient(colors: [green.opacity(0.22), green.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                .background(.background)
                .ignoresSafeArea()
        }
        .animation(.spring(duration: 0.45), value: onboarding.step)
    }

    @ViewBuilder private var primaryButton: some View {
        switch onboarding.step {
        case .welcome:
            PrimaryButton("Get Started") { next() }
        case .permission:
            if onboarding.permission == .allowed {
                PrimaryButton("Continue") { next() }
            } else if onboarding.permission == .denied {
                PrimaryButton("Open System Settings") { AudioPermission.openSettings() }
            } else {
                PrimaryButton("Allow Audio Access") {
                    AudioPermission.request { _ in
                        onboarding.permission = AudioPermission.status
                        if onboarding.permission == .allowed { next() }
                    }
                }
            }
        case .model:
            if case .failed = onboarding.model {
                PrimaryButton("Try Again") { onboarding.onRetry() }
            } else {
                PrimaryButton(onboarding.model == .ready ? "Continue" : "Getting ready…") { next() }
                    .disabled(onboarding.model != .ready)
            }
        case .screen:
            if onboarding.screenAllowed {
                PrimaryButton("Continue") { next() }
            } else {
                PrimaryButton("Allow Screen Recording") {
                    onboarding.onScreenRecording()
                    _ = SnapTranslate.canCapture()
                    next()
                }
                Button("Not Now") { next() }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        case .done:
            PrimaryButton("Start Captions") { onboarding.onFinish() }
        }
    }

    private func next() {
        onboarding.step = Onboarding.Step(rawValue: onboarding.step.rawValue + 1) ?? .done
    }
}

private struct PrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    init(_ title: LocalizedStringKey, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)
                .frame(width: 300, height: 48)
                .background(green.opacity(enabled ? 1 : 0.45), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

private struct Header: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 26) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Header(title: "Welcome to Parakeet", subtitle: "Live captions for everything your Mac plays.")
            VStack(spacing: 14) {
                CaptionPreview()
                Note("Runs on your Mac. Audio never leaves it.")
            }
        }
    }
}

/// The real caption box, typing sample lines in a few languages.
private struct CaptionPreview: View {
    @State private var captions = Captions()
    private static let lines = [
        "Good morning everyone, and welcome to the weekly sync.",
        "안녕하세요, 오늘 회의를 시작하겠습니다.",
        "最初の議題は来期の予算です。",
        "¿Alguna pregunta? Perfecto, sigamos.",
    ]

    var body: some View {
        CaptionView(captions: captions)
            .frame(width: 440, height: 116)
            .environment(\.colorScheme, .dark)
            .task {
                for line in Self.lines.cycled() {
                    captions.lock(line)
                    try? await Task.sleep(for: .seconds(2.6))
                    if Task.isCancelled { return }
                }
            }
    }
}

private struct Note: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize()
    }
}

private struct PermissionStep: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 26) {
            Symbol("speaker.wave.2.bubble.fill")
            Header(title: "Let Parakeet hear your Mac",
                   subtitle: "Parakeet captions what your Mac plays. It doesn't use your microphone, and audio is turned into text right here, never recorded or sent anywhere.")
            Group {
                switch onboarding.permission {
                case .allowed:
                    Label("Audio access allowed", systemImage: "checkmark.circle.fill").foregroundStyle(green)
                case .denied:
                    Text("Audio access is off. Open System Settings and turn on Parakeet.")
                        .foregroundStyle(.secondary)
                case .unknown:
                    Text("macOS will ask you to confirm.").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        // Coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            onboarding.permission = AudioPermission.status
        }
    }
}

private struct ModelStep: View {
    let state: Onboarding.ModelState

    var body: some View {
        VStack(spacing: 26) {
            Symbol("cpu")
            Header(title: "Setting up the speech model",
                   subtitle: "Parakeet downloads its speech model once (about 640 MB), then prepares it for your Mac's Neural Engine.")
            VStack(spacing: 12) {
                switch state {
                case .waiting:
                    ProgressView().controlSize(.small)
                    Caption("Starting…")
                case .downloading(let fraction):
                    ProgressView(value: fraction).tint(green)
                    Caption("Downloading… \(Int(fraction * 640)) of 640 MB")
                case .preparing:
                    ProgressView().controlSize(.small)
                    Caption("Preparing for the Neural Engine. This takes about a minute, only the first time.")
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(green)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 360)
        }
    }
}

private struct DoneStep: View {
    @Binding var openAtLogin: Bool

    var body: some View {
        VStack(spacing: 26) {
            Symbol("checkmark.seal.fill")
            Header(title: "You're all set",
                   subtitle: "Captions appear at the bottom of your screen whenever something speaks. Drag the box anywhere you like.")
            // Two tips, kept together: the menu bar, and ⇧⌘1.
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 15))
                        .frame(width: 48, height: 26)  // both badges one size, so the tips line up
                        .background(.secondary.opacity(0.15), in: .rect(cornerRadius: 6))
                    Text("Parakeet lives in the menu bar. Click it to turn captions off (⌘L) or copy the transcript.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 440, alignment: .leading)
                HStack(spacing: 10) {
                    Text("⇧⌘1")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 48, height: 26)
                        .background(.secondary.opacity(0.15), in: .rect(cornerRadius: 6))
                    Text("Press ⇧⌘1 to translate the text on your screen, right where it is.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 440, alignment: .leading)
            }
            Toggle("Open Parakeet when I log in", isOn: $openAtLogin)
                .toggleStyle(.switch)
                .tint(green)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

/// ⇧⌘1 needs Screen Recording; it's optional, and asked here only after the
/// model is in, since macOS may ask to quit and reopen Parakeet to apply it.
private struct ScreenStep: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 26) {
            Symbol("text.viewfinder")
            Header(title: "Translate what's on screen",
                   subtitle: "Press ⇧⌘1 and Parakeet reads the text on your screen and translates it right where it is, on this Mac. Nothing is recorded or sent anywhere.")
            Group {
                if onboarding.screenAllowed {
                    Label("Screen Recording allowed", systemImage: "checkmark.circle.fill").foregroundStyle(green)
                } else {
                    Text("macOS will ask for Screen Recording, and may ask to reopen Parakeet.").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        // Coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            onboarding.screenAllowed = CGPreflightScreenCaptureAccess()
        }
    }
}

private struct Symbol: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 44, weight: .medium))
            .foregroundStyle(green)
            .frame(width: 84, height: 84)
    }
}

private struct Caption: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

private extension Array {
    /// Loops over the elements forever.
    func cycled() -> AnySequence<Element> {
        AnySequence { () -> AnyIterator<Element> in
            var i = 0
            return AnyIterator { defer { i += 1 }; return self.isEmpty ? nil : self[i % self.count] }
        }
    }
}
