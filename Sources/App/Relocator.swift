import AppKit

/// Offers to copy DeskKit into /Applications on its first launch from anywhere else.
/// A downloaded app runs translocated, and a login item pointing at a translocated path breaks.
@MainActor
enum Relocator {
    static let destination = URL(fileURLWithPath: "/Applications/DeskKit.app")

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Returns true when DeskKit is quitting so the copy in /Applications can start.
    static func offerToMoveIfNeeded() -> Bool {
        guard !isInApplications, !Settings.shared.declinedMoveToApplications else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move DeskKit to your Applications folder?"
        alert.informativeText = "DeskKit can only open at login from the Applications folder. It will copy itself there and start again."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Settings.shared.declinedMoveToApplications = true
            return false
        }
        do {
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                try files.trashItem(at: destination, resultingItemURL: nil)
            }
            try files.copyItem(at: Bundle.main.bundleURL, to: destination)
            run("/usr/bin/xattr", "-dr", "com.apple.quarantine", destination.path)
            relaunch(destination)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private static func run(_ tool: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
