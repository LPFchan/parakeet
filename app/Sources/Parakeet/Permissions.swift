import AppKit
import PermissionFlow

/// Screen Recording, for ⇧⌘1: the welcome window and ⇧⌘1 itself open
/// System Settings at the right list with PermissionFlow's floating panel
/// beside it, to drag Parakeet into. No system prompt on top of it.
@MainActor
enum ScreenRecording {
    static let controller = PermissionFlow.makeController(configuration: .init(requiredAppURLs: [Bundle.main.bundleURL]))

    static func open() {
        let mouse = NSEvent.mouseLocation
        controller.authorize(pane: .screenRecording, sourceFrameInScreen: CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32))
    }

    /// Whether Parakeet may capture the screen right now. Asked of a fresh
    /// copy of Parakeet: a running app keeps its first answer, so a grant
    /// made in System Settings meanwhile never shows up in-process. Blocks
    /// for the child's run (tens of milliseconds); keep it off the main thread.
    nonisolated static var allowed: Bool {
        let checker = Process()
        checker.executableURL = Bundle.main.executableURL
        checker.arguments = [checkFlag]
        checker.standardOutput = FileHandle.nullDevice
        checker.standardError = FileHandle.nullDevice
        guard (try? checker.run()) != nil else { return CGPreflightScreenCaptureAccess() }
        checker.waitUntilExit()
        return checker.terminationStatus == 0
    }

    /// Started as the checker: answer through the exit status, before any UI.
    nonisolated static let checkFlag = "--check-screen-recording"
}
